import Foundation

/// Centralized App Store & StoreKit 2 identifiers resolved for VoxelRay.
public enum StoreConfig {
    public static let bundleID = "com.voxelray.app"
    public static let proProductID = "\(bundleID).pro"
    public static let crystalPackProductID = "\(bundleID).materials.crystal"

    public static let allProductIDs: [String] = [
        proProductID,
        crystalPackProductID,
    ]
}
