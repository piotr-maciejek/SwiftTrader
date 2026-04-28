import SwiftUI

struct ChartLoadingCard: View {
    let status: LoadingStatus
    var onRetry: (() -> Void)?
    var onForceReconnect: (() -> Void)?
    @State private var showDetail = false

    var body: some View {
        VStack(spacing: 8) {
            if isExhausted {
                exhaustedHeader
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status.message)
                        .font(.system(size: 13, weight: .medium))
                }
            }
            if let err = status.lastError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                    Text(err)
                        .font(.system(size: 10))
                        .lineLimit(2)
                }
                .foregroundStyle(.secondary)
            }
            if (showDetail || isExhausted), let detail = status.detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            if isExhausted {
                HStack(spacing: 8) {
                    if let onRetry {
                        Button("Retry", action: onRetry)
                            .keyboardShortcut(.defaultAction)
                    }
                    if let onForceReconnect {
                        Button("Force reconnect", action: onForceReconnect)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .onAppear {
            guard status.detail != nil, !isExhausted else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1500))
                if !Task.isCancelled { showDetail = true }
            }
        }
    }

    private var isExhausted: Bool {
        if case .exhausted = status.stage { return true }
        return false
    }

    private var exhaustedHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.orange)
            Text(status.message)
                .font(.system(size: 13, weight: .semibold))
        }
    }
}
