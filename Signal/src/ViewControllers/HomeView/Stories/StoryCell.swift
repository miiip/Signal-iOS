//
//  Copyright (c) 2022 Open Whisper Systems. All rights reserved.
//

import Foundation
import UIKit
import SignalMessaging

class StoryCell: UITableViewCell {
    static let reuseIdentifier = "StoryCell"

    let nameLabel = UILabel()
    let timestampLabel = UILabel()
    let avatarView = ConversationAvatarView(sizeClass: .fiftySix, localUserDisplayMode: .asUser, useAutolayout: true)
    let attachmentThumbnail = UIView()
    let replyImageView = UIImageView()

    let contentHStackView = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        backgroundColor = .clear

        replyImageView.autoSetDimensions(to: CGSize(square: 20))
        replyImageView.contentMode = .scaleAspectFit

        let vStack = UIStackView(arrangedSubviews: [nameLabel, timestampLabel, replyImageView])
        vStack.axis = .vertical
        vStack.alignment = .leading

        contentHStackView.addArrangedSubviews([avatarView, vStack, .hStretchingSpacer(), attachmentThumbnail])
        contentHStackView.axis = .horizontal
        contentHStackView.alignment = .center
        contentHStackView.spacing = 16

        contentView.addSubview(contentHStackView)
        contentHStackView.autoPinEdgesToSuperviewMargins()

        attachmentThumbnail.autoSetDimensions(to: CGSize(width: 56, height: 84))
        attachmentThumbnail.layer.cornerRadius = 12
        attachmentThumbnail.clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with model: IncomingStoryViewModel) {
        configureTimestamp(with: model)

        switch model.context {
        case .authorUuid:
            replyImageView.image = #imageLiteral(resourceName: "reply-solid-20").withRenderingMode(.alwaysTemplate)
        case .groupId:
            replyImageView.image = #imageLiteral(resourceName: "messages-solid-20").withRenderingMode(.alwaysTemplate)
        case .none:
            owsFailDebug("Unexpected context")
        }

        replyImageView.isHidden = !model.hasReplies
        replyImageView.tintColor = Theme.secondaryTextAndIconColor

        nameLabel.font = .ows_dynamicTypeHeadline
        nameLabel.textColor = Theme.primaryTextColor
        nameLabel.text = model.latestMessageName

        avatarView.updateWithSneakyTransactionIfNecessary { config in
            config.dataSource = model.latestMessageAvatarDataSource
            config.storyState = model.hasUnviewedMessages ? .unviewed : .viewed
            config.usePlaceholderImages()
        }

        attachmentThumbnail.backgroundColor = Theme.washColor
        attachmentThumbnail.removeAllSubviews()

        switch model.latestMessageAttachment {
        case .file(let attachment):
            if let pointer = attachment as? TSAttachmentPointer {
                let pointerView = UIView()

                if let blurHashImageView = buildBlurHashImageViewIfAvailable(pointer: pointer) {
                    pointerView.addSubview(blurHashImageView)
                    blurHashImageView.autoPinEdgesToSuperviewEdges()
                }

                let downloadStateView = buildDownloadStateView(for: pointer)
                pointerView.addSubview(downloadStateView)
                downloadStateView.autoPinEdgesToSuperviewEdges()

                attachmentThumbnail.addSubview(pointerView)
                pointerView.autoPinEdgesToSuperviewEdges()
            } else if let stream = attachment as? TSAttachmentStream {
                let backgroundImageView = buildBackgroundImageView(stream: stream)
                attachmentThumbnail.addSubview(backgroundImageView)
                backgroundImageView.autoPinEdgesToSuperviewEdges()
                let imageView = buildThumbnailImageView(stream: stream)
                attachmentThumbnail.addSubview(imageView)
                imageView.autoPinEdgesToSuperviewEdges()
            } else {
                owsFailDebug("Unexpected attachment type \(type(of: attachment))")
            }
        case .text(let attachment):
            let textView = TextAttachmentView(attachment: attachment)
            // We render the textView at a large 3:2 size (matching the aspect of
            // the thumbnail container), so the fonts and gradients all render properly
            // for the preview. We then scale it down to render a "thumbnail" view.
            let textViewRenderSize = CGSize(width: 375, height: 563)
            textView.frame = CGRect(origin: .zero, size: textViewRenderSize)

            let layerView = OWSLayerView(frame: .zero) { view in
                textView.transform = .scale(view.width / textViewRenderSize.width)
                textView.center = view.center
            }
            layerView.addSubview(textView)

            attachmentThumbnail.addSubview(layerView)
            layerView.autoPinEdgesToSuperviewEdges()
        case .missing:
            // TODO: error state
            break
        }
    }

    private func buildBackgroundImageView(stream: TSAttachmentStream) -> UIView {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill

        stream.thumbnailImageSmall {
            imageView.image = $0
        } failure: {
            owsFailDebug("Failed to generate thumbnail")
        }

        let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
        imageView.addSubview(blurView)
        blurView.autoPinEdgesToSuperviewEdges()

        return imageView
    }

    private func buildThumbnailImageView(stream: TSAttachmentStream) -> UIView {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.layer.minificationFilter = .trilinear
        imageView.layer.magnificationFilter = .trilinear
        imageView.layer.allowsEdgeAntialiasing = true

        stream.thumbnailImageSmall {
            imageView.image = $0
        } failure: {
            owsFailDebug("Failed to generate thumbnail")
        }

        return imageView
    }

    private func buildBlurHashImageViewIfAvailable(pointer: TSAttachmentPointer) -> UIView? {
        guard let blurHash = pointer.blurHash, let blurHashImage = BlurHash.image(for: blurHash) else {
            return nil
        }
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.layer.minificationFilter = .trilinear
        imageView.layer.magnificationFilter = .trilinear
        imageView.layer.allowsEdgeAntialiasing = true
        imageView.image = blurHashImage
        return imageView
    }

    private static let mediaCache = CVMediaCache()
    private func buildDownloadStateView(for pointer: TSAttachmentPointer) -> UIView {
        let view = UIView()

        let progressView = CVAttachmentProgressView(
            direction: .download(attachmentPointer: pointer),
            style: .withCircle,
            isDarkThemeEnabled: true,
            mediaCache: Self.mediaCache
        )
        view.addSubview(progressView)
        progressView.autoSetDimensions(to: progressView.layoutSize)
        progressView.autoCenterInSuperview()

        return view
    }

    func configureTimestamp(with model: IncomingStoryViewModel) {
        timestampLabel.font = .ows_dynamicTypeSubheadline
        timestampLabel.textColor = Theme.secondaryTextAndIconColor
        timestampLabel.text = DateUtil.formatTimestampRelatively(model.latestMessageTimestamp)
    }
}
