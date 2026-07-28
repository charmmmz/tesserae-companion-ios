import TesseraeKit
import UIKit

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground

        let icon = UIImageView(image: UIImage(systemName: "paperplane.circle.fill"))
        icon.tintColor = UIColor(red: 13 / 255, green: 140 / 255, blue: 126 / 255, alpha: 1)
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 42)
        icon.contentMode = .scaleAspectFit

        let titleLabel = UILabel()
        titleLabel.text = "Send to Tesserae"
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.textAlignment = .center

        let detailLabel = UILabel()
        detailLabel.text = "The Share Sheet target is registered. Display selection and upload will be connected in the next slice."
        detailLabel.font = .preferredFont(forTextStyle: .body)
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0

        let closeButton = UIButton(type: .system)
        closeButton.setTitle("Close", for: .normal)
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [icon, titleLabel, detailLabel, closeButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    @objc private func close() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
