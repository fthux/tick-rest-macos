import SwiftUI
import TickRestCore

struct LoginApprovalNotice: View {
    @ObservedObject var model: AppController
    var body: some View {
        if model.loginNeedsApproval {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("general.login_approval_help"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.text("general.login_settings")) { model.openLoginSettings() }
            }
        }
    }
}

struct NotificationPermissionControls: View {
    @ObservedObject var model: AppController
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(L10n.text(model.notificationActionTitle)) { model.requestNotifications() }
                .disabled(!model.canManageNotifications)
            if model.notificationStatus == "permission.denied" {
                Text(L10n.text("general.notifications_denied_help"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
