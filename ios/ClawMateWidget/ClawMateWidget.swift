import WidgetKit
import SwiftUI

@main
struct ClawMateWidgetBundle: WidgetBundle {
    var body: some Widget {
        QuickConnectWidget()
        TerminalPreviewWidget()
        ServerMonitorWidget()
    }
}
