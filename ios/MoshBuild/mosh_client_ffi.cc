// mosh_client_ffi.cc — C API wrapper around mosh STMClient for Flutter FFI
//
// Replaces POSIX terminal I/O with ring buffers:
//   - User input: written via mosh_client_send_input(), consumed by network thread
//   - Terminal output: produced by network thread, read via mosh_client_receive_output()
//
// The network loop runs on a background pthread, using select() on the UDP socket only
// (no STDIN). The Dart side polls receive_output at 32ms intervals.

#include "mosh_client_ffi.h"

#include <pthread.h>
#include <clocale>
#include <cstring>
#include <string>
#include <mutex>
#include <atomic>
#include <vector>

#include "src/include/config.h"
#include "src/crypto/crypto.h"
#include "src/network/networktransport.h"
#include "src/network/networktransport-impl.h"
#include "src/statesync/completeterminal.h"
#include "src/statesync/user.h"
#include "src/terminal/terminalframebuffer.h"
#include "src/terminal/terminaldisplay.h"
#include "src/frontend/terminaloverlay.h"
#include "src/util/timestamp.h"
#include "src/util/select.h"
#include "src/util/locale_utils.h"

// Ring buffer for lock-free single-producer single-consumer byte transfer
class RingBuffer {
public:
    explicit RingBuffer(size_t capacity = 256 * 1024)
        : buf_(capacity), head_(0), tail_(0) {}

    size_t write(const uint8_t* data, size_t len) {
        size_t h = head_.load(std::memory_order_relaxed);
        size_t t = tail_.load(std::memory_order_acquire);
        size_t cap = buf_.size();
        size_t avail = (cap - 1 - h + t) % cap;
        if (len > avail) len = avail;
        for (size_t i = 0; i < len; i++) {
            buf_[(h + i) % cap] = data[i];
        }
        head_.store((h + len) % cap, std::memory_order_release);
        return len;
    }

    size_t write_str(const std::string& s) {
        return write(reinterpret_cast<const uint8_t*>(s.data()), s.size());
    }

    size_t read(uint8_t* out, size_t max_len) {
        size_t h = head_.load(std::memory_order_acquire);
        size_t t = tail_.load(std::memory_order_relaxed);
        size_t cap = buf_.size();
        size_t avail = (cap + h - t) % cap;
        if (max_len > avail) max_len = avail;
        for (size_t i = 0; i < max_len; i++) {
            out[i] = buf_[(t + i) % cap];
        }
        tail_.store((t + max_len) % cap, std::memory_order_release);
        return max_len;
    }

private:
    std::vector<uint8_t> buf_;
    std::atomic<size_t> head_;
    std::atomic<size_t> tail_;
};

enum MoshState {
    MOSH_CONNECTING = 0,
    MOSH_CONNECTED = 1,
    MOSH_DISCONNECTED = 2,
    MOSH_ERROR = 3
};

struct MoshClient {
    std::string host;
    std::string port_str;
    std::string key;
    int term_width;
    int term_height;

    using NetworkType = Network::Transport<Network::UserStream, Terminal::Complete>;

    std::shared_ptr<NetworkType> network;
    Terminal::Display display;
    Terminal::Framebuffer local_fb;
    Terminal::Framebuffer new_state;
    Overlay::OverlayManager overlays;
    bool repaint_requested;

    RingBuffer input_buf;   // user input → network thread
    RingBuffer output_buf;  // terminal output → Dart

    std::atomic<int> state;
    std::atomic<bool> running;
    pthread_t thread;
    bool thread_started;

    std::atomic<int> rtt_ms;
    std::atomic<int64_t> last_heard_ms;

    // Pending resize
    std::mutex resize_mutex;
    int pending_width;
    int pending_height;
    bool resize_pending;

    MoshClient(const char* h, int p, const char* k, int w, int ht)
        : host(h)
        , port_str(std::to_string(p))
        , key(k)
        , term_width(w)
        , term_height(ht)
        , display(false)  // don't use environment for terminfo
        , local_fb(w, ht)
        , new_state(1, 1)
        , repaint_requested(true)
        , state(MOSH_CONNECTING)
        , running(false)
        , thread_started(false)
        , rtt_ms(-1)
        , last_heard_ms(0)
        , pending_width(w)
        , pending_height(ht)
        , resize_pending(false)
    {}
};

// Network thread entry point
static void* mosh_network_thread(void* arg) {
    MoshClient* c = static_cast<MoshClient*>(arg);

    try {
        // Set UTF-8 locale for mbrtowc/wcrtomb (critical for CJK characters)
        setenv("LANG", "en_US.UTF-8", 1);
        setenv("LC_ALL", "en_US.UTF-8", 1);
        if (!setlocale(LC_ALL, "en_US.UTF-8")) {
            if (!setlocale(LC_ALL, "")) {
                setlocale(LC_ALL, "C");
                setlocale(LC_CTYPE, "UTF-8");
            }
        }

        // Create the network transport
        Network::UserStream blank;
        Terminal::Complete local_terminal(c->term_width, c->term_height);
        c->network = std::make_shared<MoshClient::NetworkType>(
            blank, local_terminal, c->key.c_str(), c->host.c_str(), c->port_str.c_str());

        c->network->set_send_delay(1);
        c->network->get_current_state().push_back(
            Parser::Resize(c->term_width, c->term_height));

        // Write initial frame
        std::string init = c->display.new_frame(false, c->local_fb, c->local_fb);
        c->output_buf.write_str(init);

        Select& sel = Select::get_instance();

        while (c->running.load(std::memory_order_relaxed)) {
            // Process pending resize
            {
                std::lock_guard<std::mutex> lk(c->resize_mutex);
                if (c->resize_pending) {
                    c->resize_pending = false;
                    c->network->get_current_state().push_back(
                        Parser::Resize(c->pending_width, c->pending_height));
                    c->local_fb.resize(c->pending_width, c->pending_height);
                    c->repaint_requested = true;
                }
            }

            // Process user input from ring buffer
            uint8_t inbuf[16384];
            size_t inlen = c->input_buf.read(inbuf, sizeof(inbuf));
            if (inlen > 0) {
                bool paste = inlen > 100;
                if (paste) {
                    c->overlays.get_prediction_engine().reset();
                }
                for (size_t i = 0; i < inlen; i++) {
                    if (!paste) {
                        c->overlays.get_prediction_engine().new_user_byte(inbuf[i], c->local_fb);
                    }
                    c->network->get_current_state().push_back(
                        Parser::UserByte(inbuf[i]));
                }
            }

            // Render frame
            c->new_state = c->network->get_latest_remote_state().state.get_fb();
            c->overlays.apply(c->new_state);
            std::string diff = c->display.new_frame(!c->repaint_requested, c->local_fb, c->new_state);
            if (!diff.empty()) {
                c->output_buf.write_str(diff);
            }
            c->repaint_requested = false;
            c->local_fb = c->new_state;

            // Tick: send pending state diffs and keepalives via UDP
            try {
                c->network->tick();
            } catch (const std::exception& e) {
                c->output_buf.write_str("\r\n[Connection lost]\r\n");
                c->state.store(MOSH_DISCONNECTED, std::memory_order_relaxed);
                return nullptr;
            }

            // Update RTT
            double srtt = c->network->get_SRTT();
            if (srtt >= 0) {
                c->rtt_ms.store(static_cast<int>(srtt), std::memory_order_relaxed);
            }

            // Update connection state
            if (c->network->get_latest_remote_state().timestamp != static_cast<uint64_t>(-1)) {
                c->state.store(MOSH_CONNECTED, std::memory_order_relaxed);
                uint64_t now = Network::timestamp();
                uint64_t server_ts = c->network->get_latest_remote_state().timestamp;
                c->last_heard_ms.store((now - server_ts) / 1000, std::memory_order_relaxed);
            }

            // Update notification overlays
            c->overlays.get_notification_engine().server_heard(
                c->network->get_latest_remote_state().timestamp);
            c->overlays.get_notification_engine().server_acked(
                c->network->get_sent_state_acked_timestamp());
            c->overlays.get_prediction_engine().set_local_frame_acked(
                c->network->get_sent_state_acked());
            c->overlays.get_prediction_engine().set_send_interval(
                c->network->send_interval());
            c->overlays.get_prediction_engine().set_local_frame_late_acked(
                c->network->get_latest_remote_state().state.get_echo_ack());

            // Wait for network events (select on UDP socket fds)
            int wait_time = std::min(c->network->wait_time(), c->overlays.wait_time());
            wait_time = std::min(wait_time, 50); // max 50ms to stay responsive

            sel.clear_fds();
            std::vector<int> fds = c->network->fds();
            for (int fd : fds) {
                sel.add_fd(fd);
            }
            sel.select(wait_time);

            bool network_ready = false;
            for (int fd : fds) {
                if (sel.read(fd)) {
                    network_ready = true;
                }
            }
            if (network_ready) {
                try {
                    c->network->recv();
                } catch (const std::exception& e) {
                    c->output_buf.write_str("\r\n[Connection lost]\r\n");
                    c->state.store(MOSH_DISCONNECTED, std::memory_order_relaxed);
                    return nullptr;
                }
            }

            // Check for shutdown
            if (c->network->shutdown_in_progress() && c->network->shutdown_acknowledged()) {
                break;
            }
            if (c->network->counterparty_shutdown_ack_sent()) {
                break;
            }
        }
    } catch (const std::exception& e) {
        std::string err = "\r\n[mosh error: ";
        err += e.what();
        err += "]\r\n";
        c->output_buf.write_str(err);
        c->state.store(MOSH_ERROR, std::memory_order_relaxed);
        return nullptr;
    }

    c->state.store(MOSH_DISCONNECTED, std::memory_order_relaxed);
    return nullptr;
}

extern "C" {

MoshClient* mosh_client_create(const char* host, int port, const char* key, int w, int h) {
    try {
        return new MoshClient(host, port, key, w, h);
    } catch (...) {
        return nullptr;
    }
}

int mosh_client_start(MoshClient* client) {
    if (!client || client->thread_started) return -1;
    client->running.store(true, std::memory_order_relaxed);
    int ret = pthread_create(&client->thread, nullptr, mosh_network_thread, client);
    if (ret != 0) return -1;
    client->thread_started = true;
    return 0;
}

void mosh_client_send_input(MoshClient* client, const uint8_t* data, int len) {
    if (!client || len <= 0) return;
    client->input_buf.write(data, len);
}

int mosh_client_receive_output(MoshClient* client, uint8_t* buf, int max_len) {
    if (!client) return -1;
    if (client->state.load(std::memory_order_relaxed) == MOSH_DISCONNECTED ||
        client->state.load(std::memory_order_relaxed) == MOSH_ERROR) {
        // Drain remaining output
        size_t n = client->output_buf.read(buf, max_len);
        return n > 0 ? (int)n : -1;
    }
    return (int)client->output_buf.read(buf, max_len);
}

void mosh_client_resize(MoshClient* client, int width, int height) {
    if (!client) return;
    std::lock_guard<std::mutex> lk(client->resize_mutex);
    client->pending_width = width;
    client->pending_height = height;
    client->resize_pending = true;
}

int mosh_client_get_state(MoshClient* client) {
    if (!client) return MOSH_ERROR;
    return client->state.load(std::memory_order_relaxed);
}

int mosh_client_get_rtt(MoshClient* client) {
    if (!client) return -1;
    return client->rtt_ms.load(std::memory_order_relaxed);
}

int64_t mosh_client_get_last_heard(MoshClient* client) {
    if (!client) return -1;
    return client->last_heard_ms.load(std::memory_order_relaxed);
}

void mosh_client_stop(MoshClient* client) {
    if (!client) return;
    client->running.store(false, std::memory_order_relaxed);
    if (client->network && !client->network->shutdown_in_progress()) {
        client->network->start_shutdown();
    }
}

void mosh_client_destroy(MoshClient* client) {
    if (!client) return;
    client->running.store(false, std::memory_order_relaxed);
    if (client->thread_started) {
        pthread_join(client->thread, nullptr);
    }
    delete client;
}

} // extern "C"
