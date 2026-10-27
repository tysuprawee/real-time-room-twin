import SwiftUI

/// Shown when a model is ready: the picture greys out and the model pops out
/// of it and spins. Dragging the model turns it and pinching zooms; swiping up
/// anywhere else sends it to RoomTwin Viewer on the Mac. Pre-load sends it
/// ahead, so the Mac has it loaded and the swipe shows it at once. Save to My Objects
/// keeps it in the account, to add to room previews later.
struct ModelReveal: View {
    let model: URL
    let backdrop: UIImage?
    /// Where the object is in the backdrop, 0...1.
    let origin: CGPoint
    @ObservedObject var sender: ModelSender
    let onAR: () -> Void
    let onClose: () -> Void
    /// Set for an object opened from My Objects: it's saved already, so
    /// there's no Save button, and it goes to the Mac under this name.
    var savedName: String? = nil

    @State private var popped = false
    /// How far the model is dragged up (negative).
    @State private var lift: CGFloat = 0
    @State private var flying = false
    @State private var shown = true
    @EnvironmentObject private var account: Account
    @State private var naming = false
    @State private var name = ""
    @State private var saving: SaveState = .idle

    private enum SaveState: Equatable {
        case idle, saving, saved, failed(String)
    }

    var body: some View {
        GeometryReader { geometry in
            let picture = fitted(backdrop?.size ?? geometry.size, in: geometry.size)
            let start = CGPoint(x: picture.minX + origin.x * picture.width, y: picture.minY + origin.y * picture.height)
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height * 0.42)
            let side = min(geometry.size.width, geometry.size.height) * 0.95
            ZStack {
                ZStack {
                    Color.black
                    if let backdrop {
                        Image(uiImage: backdrop)
                            .resizable()
                            .frame(width: picture.width, height: picture.height)
                            .position(x: picture.midX, y: picture.midY)
                            .saturation(popped ? 0 : 1)
                            .brightness(popped ? -0.3 : 0)
                            .blur(radius: popped ? 5 : 0)
                    }
                }
                .contentShape(Rectangle())
                .gesture(swipeUp)
                SpinningModel(url: model)
                    .frame(width: side, height: side)
                    .scaleEffect(!popped || !shown ? 0.15 : flying ? 0.4 : 1 + lift / 1500)
                    .opacity(popped && shown ? 1 : 0)
                    .position(popped ? center : start)
                    .offset(y: flying ? -geometry.size.height : lift)
                controls
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.62).delay(0.15)) { popped = true }
        }
        .task(id: sender.status) {
            guard sender.status != nil else { return }
            try? await Task.sleep(for: .seconds(2.5))
            sender.status = nil
        }
    }

    private var controls: some View {
        VStack(spacing: 14) {
            if let status = sender.status {
                Text(status)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
            Text("Drag to turn · pinch to zoom")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
            Group {
                if let mac = sender.knownMac {
                    VStack(spacing: 2) {
                        if #available(iOS 18.0, *) {
                            Image(systemName: "chevron.up")
                                .symbolEffect(.bounce, options: .repeating.speed(0.5))
                        } else {
                            Image(systemName: "chevron.up")
                                .symbolEffect(.bounce, value: popped)
                        }
                        Text(sender.preloadState(for: model) == .ready ? "Swipe up here to show it on \(mac)"
                             : "Swipe up here to send to \(mac)")
                    }
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                } else {
                    Text("Open RoomTwin Viewer on your Mac to send this model there")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(swipeUp)
            if let mac = sender.knownMac {
                if sender.canPreload(on: mac) {
                    preloadButton(mac)
                } else {
                    // An older Viewer would show a preload at once and never say it's ready.
                    Text("Update RoomTwin Viewer on \(mac) to pre-load")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            if savedName == nil { saveButton }
            HStack(spacing: 12) {
                Button("Close", systemImage: "xmark", action: onClose)
                    .buttonStyle(.bordered)
                Button("View in AR", systemImage: "arkit", action: onAR)
                    .buttonStyle(.bordered)
                ShareLink(item: model) { Label("Share", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.bordered)
            }
            .tint(.white)
        }
        .padding(.horizontal)
        .padding(.top, 60)
        .padding(.bottom, 40)
        .animation(.easeInOut(duration: 0.25), value: sender.status)
    }

    /// Loads the model on the Mac out of sight, so the swipe shows it at once.
    private func preloadButton(_ mac: String) -> some View {
        Group {
            switch sender.preloadState(for: model) {
            case .none:
                Button("Pre-load on \(mac)", systemImage: "arrow.down.circle") {
                    sender.preload(model, name: transferName)
                }
            case .loading:
                Label { Text("Pre-loading on \(mac)…") } icon: { ProgressView().tint(.white) }
            case .ready:
                Label { Text("Pre-loaded on \(mac)") } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            case .failed(let message):
                Button("Pre-load failed: \(message) Tap to retry.", systemImage: "exclamationmark.triangle") {
                    sender.preload(model, name: transferName)
                }
            }
        }
        .font(.footnote.weight(.medium))
        .buttonStyle(.borderedProminent)
        .tint(.white.opacity(0.25))
        .foregroundStyle(.white)
        .animation(.easeInOut(duration: 0.2), value: sender.preloadState(for: model))
    }

    /// The model's name on the Mac: its saved name, or its scan folder's.
    private var transferName: String {
        (savedName ?? model.deletingLastPathComponent().lastPathComponent) + ".usdz"
    }

    private var saveButton: some View {
        Group {
            switch saving {
            case .idle:
                Button("Save to My Objects", systemImage: "square.and.arrow.down.on.square") {
                    name = ""
                    naming = true
                }
            case .saving:
                Label("Saving…", systemImage: "icloud.and.arrow.up")
            case .saved:
                Label("Saved to My Objects", systemImage: "checkmark.circle.fill")
            case .failed(let message):
                Button("Couldn't save: \(message) Tap to retry.", systemImage: "exclamationmark.triangle") {
                    naming = true
                }
            }
        }
        .font(.footnote.weight(.medium))
        .buttonStyle(.borderedProminent)
        .tint(.white.opacity(0.25))
        .foregroundStyle(.white)
        .alert("Name this object", isPresented: $naming) {
            TextField("e.g. Desk chair", text: $name)
            Button("Save", action: save)
            Button("Cancel", role: .cancel) {}
        }
    }

    private func save() {
        let name = name.trimmingCharacters(in: .whitespaces).isEmpty ? "Scanned object" : name
        saving = .saving
        Task {
            do {
                try await account.save(model: model, thumbnail: backdrop, name: name)
                saving = .saved
            } catch {
                saving = .failed(error.localizedDescription)
            }
        }
    }

    private var swipeUp: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { lift = min(0, $0.translation.height) }
            .onEnded { value in
                let flung = value.translation.height < -120 || value.predictedEndTranslation.height < -350
                guard flung, sender.send(model, name: transferName) else {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { lift = 0 }
                    return
                }
                withAnimation(.easeIn(duration: 0.3)) { flying = true }
                // Once it has left the screen, grow it back in so it can still be viewed here.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(0.7))
                    shown = false
                    flying = false
                    lift = 0
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.3)) { shown = true }
                }
            }
    }

    private func fitted(_ size: CGSize, in bounds: CGSize) -> CGRect {
        let scale = min(bounds.width / max(size.width, 1), bounds.height / max(size.height, 1))
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: (bounds.width - fitted.width) / 2, y: (bounds.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }
}
