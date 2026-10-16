import Foundation

/// Friendly names for the model codes iPhones give AirPlay receivers, e.g. "iPhone18,2" →
/// "iPhone 17 Pro Max". Codes not listed here (newer phones) are shown as they are.
public func phoneModelName(_ code: String) -> String {
    phoneModels[code]?.name ?? code
}

/// The phone's screen diagonal in inches, if the model is known: an iPhone, or an Android phone
/// with its own frame.
public func phoneScreenDiagonal(_ code: String) -> Double? {
    phoneModels[code]?.diagonal ?? BezelStyle(modelCode: code).artwork?.diagonal
}

/// The longer side, in points, for a window showing a phone's picture at true-to-life size
/// relative to other phones: an iPhone 17 Pro Max (6.9", 19.5:9) gets `reference`, and every
/// other phone its own screen's size at the same scale, so an iPhone SE comes out about two-thirds
/// as tall. A phone that isn't known gets `reference`.
public func trueToLifeLongSide(reference: Double, modelCode: String?, pictureWidth: Double, pictureHeight: Double) -> Double {
    guard let diagonal = modelCode.flatMap(phoneScreenDiagonal), pictureWidth > 0, pictureHeight > 0 else {
        return reference
    }
    let longer = max(pictureWidth, pictureHeight)
    let shorter = min(pictureWidth, pictureHeight)
    let longInches = diagonal * longer / (longer * longer + shorter * shorter).squareRoot()
    let referenceInches = 6.9 * 19.5 / (19.5 * 19.5 + 9 * 9).squareRoot()
    return reference * longInches / referenceInches
}

private let phoneModels: [String: (name: String, diagonal: Double)] = [
    "iPhone10,1": ("iPhone 8", 4.7), "iPhone10,4": ("iPhone 8", 4.7),
    "iPhone10,2": ("iPhone 8 Plus", 5.5), "iPhone10,5": ("iPhone 8 Plus", 5.5),
    "iPhone10,3": ("iPhone X", 5.8), "iPhone10,6": ("iPhone X", 5.8),
    "iPhone11,2": ("iPhone XS", 5.8), "iPhone11,4": ("iPhone XS Max", 6.5), "iPhone11,6": ("iPhone XS Max", 6.5),
    "iPhone11,8": ("iPhone XR", 6.1),
    "iPhone12,1": ("iPhone 11", 6.1), "iPhone12,3": ("iPhone 11 Pro", 5.8), "iPhone12,5": ("iPhone 11 Pro Max", 6.5),
    "iPhone12,8": ("iPhone SE (2nd generation)", 4.7),
    "iPhone13,1": ("iPhone 12 mini", 5.4), "iPhone13,2": ("iPhone 12", 6.1),
    "iPhone13,3": ("iPhone 12 Pro", 6.1), "iPhone13,4": ("iPhone 12 Pro Max", 6.7),
    "iPhone14,4": ("iPhone 13 mini", 5.4), "iPhone14,5": ("iPhone 13", 6.1),
    "iPhone14,2": ("iPhone 13 Pro", 6.1), "iPhone14,3": ("iPhone 13 Pro Max", 6.7),
    "iPhone14,6": ("iPhone SE (3rd generation)", 4.7),
    "iPhone14,7": ("iPhone 14", 6.1), "iPhone14,8": ("iPhone 14 Plus", 6.7),
    "iPhone15,2": ("iPhone 14 Pro", 6.1), "iPhone15,3": ("iPhone 14 Pro Max", 6.7),
    "iPhone15,4": ("iPhone 15", 6.1), "iPhone15,5": ("iPhone 15 Plus", 6.7),
    "iPhone16,1": ("iPhone 15 Pro", 6.1), "iPhone16,2": ("iPhone 15 Pro Max", 6.7),
    "iPhone17,3": ("iPhone 16", 6.1), "iPhone17,4": ("iPhone 16 Plus", 6.7),
    "iPhone17,1": ("iPhone 16 Pro", 6.3), "iPhone17,2": ("iPhone 16 Pro Max", 6.9),
    "iPhone17,5": ("iPhone 16e", 6.1),
    "iPhone18,3": ("iPhone 17", 6.3), "iPhone18,4": ("iPhone Air", 6.5),
    "iPhone18,1": ("iPhone 17 Pro", 6.3), "iPhone18,2": ("iPhone 17 Pro Max", 6.9),
]
