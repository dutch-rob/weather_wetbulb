import SwiftUI

// AUTO-GENERATED — edit README.md and run generate_infoview.py to update.

struct InfoView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    Text("read me coming")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .navigationTitle("Info")
        .navigationBarTitleDisplayMode(.inline)
        .textSelection(.enabled)
    }
}

#Preview {
    NavigationStack {
        InfoView()
    }
}
