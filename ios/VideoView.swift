// Copyright 2023-present 650 Industries. All rights reserved.

import AVKit
import ExpoModulesCore

public final class VideoView: ExpoView, AVPlayerViewControllerDelegate {
  lazy var playerViewController = AVPlayerViewController()
  private var watermarkLabel: UILabel?
  weak var player: VideoPlayer? {
    didSet {
      playerViewController.player = player?.ref
    }
  }

  #if os(tvOS)
  var wasPlaying: Bool = false
  #endif
  var isFullscreen: Bool = false
  var isInPictureInPicture = false
  #if os(tvOS)
  let startPictureInPictureAutomatically = false
  #else
  var startPictureInPictureAutomatically = false {
    didSet {
      playerViewController.canStartPictureInPictureAutomaticallyFromInline = startPictureInPictureAutomatically
    }
  }
  #endif

  var allowPictureInPicture: Bool = false {
    didSet {
      // PiP requires `.playback` audio session category in `.moviePlayback` mode
      VideoManager.shared.setAppropriateAudioSessionOrWarn()
      playerViewController.allowsPictureInPicturePlayback = allowPictureInPicture
    }
  }

  let onPictureInPictureStart = EventDispatcher()
  let onPictureInPictureStop = EventDispatcher()
  let onFullscreenEnter = EventDispatcher()
  let onFullscreenExit = EventDispatcher()
  let onFirstFrameRender = EventDispatcher()

  var firstFrameObserver: NSKeyValueObservation?

  public override var bounds: CGRect {
    didSet {
      playerViewController.view.frame = self.bounds
    }
  }

  @objc
  public var watermarkText: String? {
    didSet {
      updateWatermark()
    }
  }

  public required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)

    VideoManager.shared.register(videoView: self)

    clipsToBounds = true
    playerViewController.delegate = self
    playerViewController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    playerViewController.view.backgroundColor = .clear
    // Now playing is managed by the `NowPlayingManager`
    #if !os(tvOS)
    playerViewController.updatesNowPlayingInfoCenter = false
    #endif

    addFirstFrameObserver()
    addSubview(playerViewController.view)
    setupWatermarkLabel()
  }

  private func setupWatermarkLabel() {
    let label = UILabel()
    label.textColor = .white
    label.backgroundColor = UIColor.black.withAlphaComponent(0.4)
    label.font = UIFont.systemFont(ofSize: 14, weight: .bold)
    label.numberOfLines = 1
    label.textAlignment = .center
    label.layer.cornerRadius = 6
    label.layer.masksToBounds = true
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    watermarkLabel = label
    
    // Constraints: Top-right corner, margin 8px
    NSLayoutConstraint.activate([
      label.topAnchor.constraint(equalTo: self.topAnchor, constant: 8),
      label.rightAnchor.constraint(equalTo: self.rightAnchor, constant: -8),
      label.heightAnchor.constraint(greaterThanOrEqualToConstant: 24)
    ])
    label.isHidden = true
  }

  private func updateWatermark() {
    if let text = watermarkText, !text.isEmpty {
      watermarkLabel?.text = text
      watermarkLabel?.isHidden = false
      watermarkLabel?.sizeToFit()
      watermarkLabel?.frame.size.width += 16 // padding
      watermarkLabel?.frame.size.height += 8
    } else {
      watermarkLabel?.isHidden = true
    }
  }


  deinit {
    VideoManager.shared.unregister(videoView: self)
    removeFirstFrameObserver()
  }

  func enterFullscreen() {
    if isFullscreen {
      return
    }
    let selectorName = "enterFullScreenAnimated:completionHandler:"
    let selectorToForceFullScreenMode = NSSelectorFromString(selectorName)

    if playerViewController.responds(to: selectorToForceFullScreenMode) {
      playerViewController.perform(selectorToForceFullScreenMode, with: true, with: nil)
    } else {
      #if os(tvOS)
      // For TV, save the currently playing state,
      // remove the view controller from its superview,
      // and present the view controller normally
      wasPlaying = player?.isPlaying == true
      self.playerViewController.view.removeFromSuperview()
      self.reactViewController().present(self.playerViewController, animated: true)
      onFullscreenEnter()
      isFullscreen = true
      #endif
    }
  }

  func exitFullscreen() {
    if !isFullscreen {
      return
    }
    let selectorName = "exitFullScreenAnimated:completionHandler:"
    let selectorToExitFullScreenMode = NSSelectorFromString(selectorName)

    if playerViewController.responds(to: selectorToExitFullScreenMode) {
      playerViewController.perform(selectorToExitFullScreenMode, with: true, with: nil)
    }
  }

  func startPictureInPicture() throws {
    if !AVPictureInPictureController.isPictureInPictureSupported() {
      throw PictureInPictureUnsupportedException()
    }

    let selectorName = "startPictureInPicture"
    let selectorToStartPictureInPicture = NSSelectorFromString(selectorName)

    if playerViewController.responds(to: selectorToStartPictureInPicture) {
      playerViewController.perform(selectorToStartPictureInPicture)
    }
  }

  func stopPictureInPicture() {
    let selectorName = "stopPictureInPicture"
    let selectorToStopPictureInPicture = NSSelectorFromString(selectorName)

    if playerViewController.responds(to: selectorToStopPictureInPicture) {
      playerViewController.perform(selectorToStopPictureInPicture)
    }
  }

  // MARK: - AVPlayerViewControllerDelegate

  #if os(tvOS)
  // TV actually presents the playerViewController, so it implements the view controller
  // dismissal delegate methods
  public func playerViewControllerWillBeginDismissalTransition(_ playerViewController: AVPlayerViewController) {
    // Start an appearance transition
    self.playerViewController.beginAppearanceTransition(true, animated: true)
  }

  public func playerViewControllerDidEndDismissalTransition(_ playerViewController: AVPlayerViewController) {
    self.onFullscreenExit()
    self.isFullscreen = false
    // Reset the bounds of the view controller and add it back to our view
    self.playerViewController.view.frame = self.bounds
    addSubview(self.playerViewController.view)
    // End the appearance transition
    self.playerViewController.endAppearanceTransition()
    // Ensure playing state is preserved
    if wasPlaying {
      self.player?.ref.play()
    } else {
      self.player?.ref.pause()
    }
  }
  #endif

  #if !os(tvOS)
  public func playerViewController(
    _ playerViewController: AVPlayerViewController,
    willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
  ) {
    onFullscreenEnter()
    isFullscreen = true
  }

  public func playerViewController(
    _ playerViewController: AVPlayerViewController,
    willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
  ) {
    // Platform's behavior is to pause the player when exiting the fullscreen mode.
    // It seems better to continue playing, so we resume the player once the dismissing animation finishes.
    let wasPlaying = player?.ref.timeControlStatus == .playing

    coordinator.animate(alongsideTransition: nil) { context in
      if !context.isCancelled {
        if wasPlaying {
          self.player?.ref.play()
        }
        self.onFullscreenExit()
        self.isFullscreen = false
      }
    }
  }
  #endif

  public func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
    isInPictureInPicture = true
    onPictureInPictureStart()
  }

  public func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
    isInPictureInPicture = false
    onPictureInPictureStop()
  }

  public override func didMoveToWindow() {
    // TV is doing a normal view controller present, so we should not execute
    // this code
    #if !os(tvOS)
    playerViewController.beginAppearanceTransition(self.window != nil, animated: true)
    #endif
  }

  public override func safeAreaInsetsDidChange() {
    super.safeAreaInsetsDidChange()
    // This is the only way that I (@behenate) found to force re-calculation of the safe-area insets for native controls
    playerViewController.view.removeFromSuperview()
    addSubview(playerViewController.view)
  }

  private func addFirstFrameObserver() {
    firstFrameObserver = playerViewController.observe(\.isReadyForDisplay, changeHandler: { [weak self] playerViewController, _ in
      if playerViewController.isReadyForDisplay {
        self?.onFirstFrameRender()
      }
    })
  }
  private func removeFirstFrameObserver() {
    firstFrameObserver?.invalidate()
    firstFrameObserver = nil
  }
}
