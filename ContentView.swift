import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.stack")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Drop RAW files or folders here")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 640, minHeight: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView()
}
