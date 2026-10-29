import SwiftUI

struct ListeningRoomWelcome: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 28) {
                    sleeve.frame(width: 170, height: 200)
                    introduction.frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack(alignment: .top, spacing: 28) {
                    step("01", "Find", "A song you know. A version you’re missing.")
                    step("02", "Listen", "Audition sources and inspect the evidence.")
                    step("03", "Keep", "Approve the recording and review its tags.")
                }
                SetupView(model: model)
            }
            .padding(32)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("THE LISTENING ROOM").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.orange)
            Text("Good music.\nThe right recording.")
                .font(.system(size: 34, weight: .medium, design: .serif))
                .fixedSize(horizontal: false, vertical: true)
            Text("Find the version you came for. Listen before you choose, with every source and uncertainty in view.")
                .font(.title3).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Button("Explore recordings", systemImage: "sparkles") { model.destination = .discover }
                Button("Your bookmarks", systemImage: "bookmark") { model.destination = .bookmarks }
            }.buttonStyle(.borderless)
        }
    }

    private var sleeve: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(.orange.opacity(0.12))
            ForEach(0..<7) { ring in
                Circle().stroke(.primary.opacity(0.10), lineWidth: 1)
                    .padding(CGFloat(12 + ring * 10))
            }
            Circle().fill(.orange).frame(width: 64, height: 64)
            Circle().fill(.background).frame(width: 8, height: 8)
            VStack {
                HStack { Text("NEEDLE").tracking(3); Spacer() }
                Spacer()
                HStack { Spacer(); Image(systemName: "waveform").font(.title2) }
            }.font(.caption.weight(.semibold)).padding(18)
        }
        .accessibilityHidden(true)
    }

    private func step(_ number: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(number).font(.caption.monospaced()).foregroundStyle(.orange)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
