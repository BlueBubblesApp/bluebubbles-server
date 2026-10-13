//  dmg-background.swift
//  Draws the picture behind the icons in the installer image.
//
//  Run by `make-dmg.sh` with `swift Packaging/dmg-background.swift OUT.tiff`, which is a
//  deliberate choice over committing a PNG or reaching for a design tool: this is a Swift
//  repository, so the release runner already has a Swift toolchain and AppKit, and that is
//  the whole dependency list. A committed binary asset would be the alternative, and it
//  would be the one thing in `Packaging/` that nobody could diff, review or re-derive.
//
//  **It writes a multi-representation TIFF, not a PNG**, and that is the part worth knowing.
//  Finder scales a background picture to the window, so a 620×420 PNG on a Retina display is
//  upscaled and visibly soft. A TIFF carrying a 620×420 and a 1240×840 representation gives
//  Finder the second to pick on a 2x display, which is the same mechanism `@2x` uses in a
//  bundle and the only one a disk image has, because there is nowhere to put an asset
//  catalogue. LZW, because it is inside a compressed image that Sparkle mounts on every
//  update: uncompressed, the two representations are five megabytes of flat gradient.
//
//  The geometry here and the icon positions in `make-dmg.sh` are ONE layout expressed in two
//  places, which is why both name the same constants: the arrow is drawn into the gap
//  between where the two icons will sit, so moving an icon without moving the arrow leaves
//  an arrow pointing at an app.

import AppKit
import Foundation

// MARK: - The layout

/// The window's content size, in points. Finder is told the same numbers.
let windowWidth: CGFloat = 620
let windowHeight: CGFloat = 420

/// Where the two icons sit, measured from the TOP-LEFT, as Finder measures them.
///
/// Kept here rather than only in the shell script so the arrow below can be drawn from one
/// to the other rather than from two numbers that happen to agree today.
let iconY: CGFloat = 205
let appIconX: CGFloat = 165
let applicationsIconX: CGFloat = 455
/// Finder draws a 128-point icon inside a 128-point box; the arrow has to clear both.
let iconSize: CGFloat = 128

// MARK: - Arguments

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
  FileHandle.standardError.write(Data("usage: dmg-background.swift OUTPUT.tiff\n".utf8))
  exit(2)
}
let outputURL = URL(fileURLWithPath: arguments[1])

// MARK: - Drawing

/// One representation of the background, at a given scale.
///
/// Everything is expressed in points and multiplied here, rather than drawn once and resized,
/// because resizing is what produced the soft text this exists to avoid: the 2x pass draws
/// the text at 2x and the glyphs are rasterised for that size.
func draw(scale: CGFloat) -> NSBitmapImageRep {
  let pixelWidth = Int(windowWidth * scale)
  let pixelHeight = Int(windowHeight * scale)
  guard
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: pixelWidth, pixelsHigh: pixelHeight,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )
  else {
    FileHandle.standardError.write(Data("error: could not allocate the bitmap\n".utf8))
    exit(1)
  }
  rep.size = NSSize(width: windowWidth, height: windowHeight)

  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  defer { NSGraphicsContext.restoreGraphicsState() }

  // AppKit's origin is bottom-left and Finder's is top-left, so everything below converts
  // once, here, rather than each call site remembering to.
  func fromTop(_ y: CGFloat) -> CGFloat { windowHeight - y }

  // The ground. A quiet vertical wash rather than a picture: the two icons are the content,
  // and a busy background is what makes an installer look like an advertisement.
  let top = NSColor(calibratedRed: 0.976, green: 0.980, blue: 0.992, alpha: 1)
  let bottom = NSColor(calibratedRed: 0.898, green: 0.925, blue: 0.973, alpha: 1)
  NSGradient(starting: top, ending: bottom)?
    .draw(in: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight), angle: -90)

  // The product, once, at the top.
  let title = "BlueBubbles"
  let titleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 26, weight: .semibold),
    .foregroundColor: NSColor(calibratedRed: 0.13, green: 0.20, blue: 0.36, alpha: 1),
  ]
  let titleSize = title.size(withAttributes: titleAttributes)
  title.draw(
    at: NSPoint(x: (windowWidth - titleSize.width) / 2, y: fromTop(58) - titleSize.height),
    withAttributes: titleAttributes)

  // The instruction. This is the reason the window is laid out at all: an image that is just
  // two icons leaves "what am I supposed to do with this" to be inferred from an arrow.
  let instruction = "Drag BlueBubbles into your Applications folder"
  let instructionAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 14, weight: .regular),
    .foregroundColor: NSColor(calibratedRed: 0.29, green: 0.35, blue: 0.47, alpha: 1),
  ]
  let instructionSize = instruction.size(withAttributes: instructionAttributes)
  instruction.draw(
    at: NSPoint(
      x: (windowWidth - instructionSize.width) / 2,
      y: fromTop(95) - instructionSize.height),
    withAttributes: instructionAttributes)

  // The arrow, in the gap between the two icons and nowhere near either. Derived from the
  // icon positions rather than typed, so the two cannot drift apart.
  let gapStart = appIconX + iconSize / 2 + 16
  let gapEnd = applicationsIconX - iconSize / 2 - 16
  let arrowY = fromTop(iconY)
  let headLength: CGFloat = 18
  let arrowColor = NSColor(calibratedRed: 0.29, green: 0.45, blue: 0.78, alpha: 0.85)
  arrowColor.setStroke()
  arrowColor.setFill()

  let shaft = NSBezierPath()
  shaft.lineWidth = 4
  shaft.lineCapStyle = .round
  shaft.move(to: NSPoint(x: gapStart, y: arrowY))
  shaft.line(to: NSPoint(x: gapEnd - headLength + 2, y: arrowY))
  shaft.stroke()

  let head = NSBezierPath()
  head.move(to: NSPoint(x: gapEnd, y: arrowY))
  head.line(to: NSPoint(x: gapEnd - headLength, y: arrowY + 11))
  head.line(to: NSPoint(x: gapEnd - headLength, y: arrowY - 11))
  head.close()
  head.fill()

  // DELIBERATELY NO LOGO. The window already has the app's own icon in it, at 128 points,
  // as one of the two things a person is meant to drag; a second copy of the mark anywhere
  // on the background is a third icon-shaped object in a window whose entire message is
  // "there are two of these, drag the left one onto the right one".

  return rep
}

// MARK: - Writing

// Both representations in one file. `NSBitmapImageRep.representationOfImageReps` is what
// packs them; writing the 1x alone is the soft-on-Retina failure described at the top.
let representations = [draw(scale: 1), draw(scale: 2)]
guard
  let data = NSBitmapImageRep.representationOfImageReps(
    in: representations, using: .tiff,
    properties: [.compressionMethod: NSBitmapImageRep.TIFFCompression.lzw.rawValue])
else {
  FileHandle.standardError.write(Data("error: could not encode the background\n".utf8))
  exit(1)
}

do {
  try data.write(to: outputURL)
} catch {
  FileHandle.standardError.write(
    Data("error: could not write \(outputURL.path): \(error.localizedDescription)\n".utf8))
  exit(1)
}
