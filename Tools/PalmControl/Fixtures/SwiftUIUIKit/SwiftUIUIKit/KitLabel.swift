import SwiftUI
import UIKit

struct KitLabel: UIViewRepresentable {
    var text: String

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.text = text
        return label
    }

    func updateUIView(_ uiView: UILabel, context: Context) {}
}
