// terminaldisplayinit_ios.cc — iOS replacement without curses dependency
// When use_environment=false, no curses calls are made.

#include "src/include/config.h"
#include "src/terminal/terminaldisplay.h"

using namespace Terminal;

Display::Display( bool use_environment )
  : has_ech( true ), has_bce( true ), has_title( true ), smcup( NULL ), rmcup( NULL )
{
    (void)use_environment;
    // On iOS we never use terminfo. Defaults are fine for xterm-compatible output.
}
