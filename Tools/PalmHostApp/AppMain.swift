import UIKit

@main
final class PalmAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        application.isIdleTimerDisabled = true
        return true
    }
}

final class PalmSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene,
              let window = NXWindowServer.shared(with: windowScene) else { return }
        let controller = PalmLogController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        PalmBootSurface()
        PalmControlHost.shared.start()
    }
}

final class PalmLogController: UIViewController {
    private let headline = UILabel()
    private let detail = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let logView = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        headline.font = .systemFont(ofSize: 28, weight: .semibold)
        headline.textColor = .white
        headline.numberOfLines = 2

        detail.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        detail.textColor = UIColor(white: 0.78, alpha: 1)
        detail.numberOfLines = 3

        progressView.trackTintColor = UIColor(white: 0.2, alpha: 1)
        progressView.progressTintColor = .white
        progressView.progress = 0

        logView.backgroundColor = .black
        logView.textColor = UIColor(white: 0.86, alpha: 1)
        logView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        logView.isEditable = false
        logView.alwaysBounceVertical = true

        let stack = UIStackView(arrangedSubviews: [headline, progressView, detail, logView])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])

        PalmHostStatus.shared.onChange = { [weak self] in
            self?.render()
        }
        render()
    }

    private func render() {
        let status = PalmHostStatus.shared.snapshot()
        headline.text = status.headline
        detail.text = status.detail
        progressView.progress = Float(status.fraction)
        logView.text = status.recent.joined(separator: "\n")
        let bottom = NSRange(location: max(logView.text.count - 1, 0), length: 1)
        logView.scrollRangeToVisible(bottom)
    }
}
