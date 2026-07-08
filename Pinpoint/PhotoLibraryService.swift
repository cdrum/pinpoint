import Foundation
import Photos
import CoreLocation
import AppKit

/// Wraps PhotoKit: authorization, finding location-less photos, fetching
/// downscaled image data for the model, and writing a location back.
@MainActor
final class PhotoLibraryService {

    /// Ask for read+write access. Returns true if we can read the library.
    func requestAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// Build the sidebar tree: "All Photos", the user's albums and folders
    /// (nested), and a "Smart Albums" group. Folders recurse.
    func fetchCollectionTree() -> [CollectionNode] {
        var nodes: [CollectionNode] = []

        // "All Photos" — the whole library, as a single selectable album.
        if let userLibrary = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil).firstObject {
            nodes.append(CollectionNode(id: userLibrary.localIdentifier,
                                        title: "All Photos",
                                        systemImage: "photo.on.rectangle.angled",
                                        album: userLibrary, children: nil))
        }

        // User albums + folders (top-level user collections, recursed).
        let topLevel = PHCollectionList.fetchTopLevelUserCollections(with: nil)
        nodes.append(contentsOf: mapCollections(topLevel))

        // Smart albums (Favorites, Recents, Screenshots, …), non-empty only.
        var smartAlbums: [CollectionNode] = []
        let smart = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil)
        smart.enumerateObjects { album, _, _ in
            guard album.assetCollectionSubtype != .smartAlbumUserLibrary,
                  album.estimatedAssetCount != 0,
                  let title = album.localizedTitle else { return }
            smartAlbums.append(CollectionNode(id: album.localIdentifier, title: title,
                                              systemImage: "sparkles", album: album, children: nil))
        }
        if !smartAlbums.isEmpty {
            smartAlbums.sort { $0.title < $1.title }
            nodes.append(CollectionNode(id: "group.smartAlbums", title: "Smart Albums",
                                        systemImage: "wand.and.stars", album: nil, children: smartAlbums))
        }

        return nodes
    }

    /// Fetch up to `limit` image assets from every album under `node`
    /// (one album for a leaf; all descendants for a folder/group), keeping only
    /// those matching `filter`.
    ///
    /// PhotoKit can't reliably predicate on `location`, so we fetch newest-first
    /// and filter in code, deduping across albums, stopping once we have enough.
    func fetchPhotos(in node: CollectionNode, filter: LocationFilter, limit: Int = 200) -> [PHAsset] {
        var assets: [PHAsset] = []
        var seen = Set<String>()

        for album in albumsUnder(node) {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

            let result = PHAsset.fetchAssets(in: album, options: options)
            result.enumerateObjects { asset, _, stop in
                let matches: Bool
                switch filter {
                case .missing: matches = asset.location == nil
                case .has:     matches = asset.location != nil
                case .all:     matches = true
                }
                if matches, seen.insert(asset.localIdentifier).inserted {
                    assets.append(asset)
                    if assets.count >= limit { stop.pointee = true }
                }
            }
            if assets.count >= limit { break }
        }
        return assets
    }

    /// The original filename (e.g. "IMG_1998.jpg"), for the history log.
    func filename(for asset: PHAsset) -> String {
        PHAssetResource.assetResources(for: asset).first?.originalFilename ?? asset.localIdentifier
    }

    /// Write `description` into the photo's Caption field.
    ///
    /// PhotoKit has no writable caption API, so we script the Photos app. Its
    /// AppleScript `description` property is the "Caption" shown in the Info
    /// panel. Requires the apple-events automation entitlement + the user
    /// granting "Pinpoint → control Photos" (first-run TCC prompt).
    ///
    /// Photos must be running first — a sandboxed app can't auto-launch it via
    /// Apple Events ("Application isn't running"), so we launch it explicitly.
    func setDescription(_ description: String, for asset: PHAsset) async throws {
        try await ensurePhotosRunning()

        // AppleScript double-quoted strings don't interpret escapes and can't
        // hold raw newlines — flatten and escape backslashes/quotes.
        let flattened = description.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let escaped = flattened
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let source = """
        tell application "Photos"
            set theItem to media item id "\(asset.localIdentifier)"
            set the description of theItem to "\(escaped)"
        end tell
        """

        guard let script = NSAppleScript(source: source) else {
            throw PinpointError.photosScript("Couldn't build the Photos script.")
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let msg = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "\(errorInfo)"
            throw PinpointError.photosScript(msg)
        }
    }

    /// Launch Photos if it isn't already running, so the Apple Event lands.
    private func ensurePhotosRunning() async throws {
        let bundleID = "com.apple.Photos"
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { !$0.isTerminated }) {
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw PinpointError.photosScript("Photos app not found.")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        // Give Photos a moment to become scriptable on a cold launch.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
    }

    // MARK: - Collection tree helpers

    private func mapCollections(_ result: PHFetchResult<PHCollection>) -> [CollectionNode] {
        var nodes: [CollectionNode] = []
        result.enumerateObjects { collection, _, _ in
            if let album = collection as? PHAssetCollection {
                nodes.append(CollectionNode(id: album.localIdentifier,
                                            title: album.localizedTitle ?? "Untitled Album",
                                            systemImage: "rectangle.stack", album: album, children: nil))
            } else if let folder = collection as? PHCollectionList {
                let children = self.mapCollections(PHCollection.fetchCollections(in: folder, options: nil))
                nodes.append(CollectionNode(id: folder.localIdentifier,
                                            title: folder.localizedTitle ?? "Untitled Folder",
                                            systemImage: "folder", album: nil, children: children))
            }
        }
        return nodes
    }

    /// Flatten a node to the concrete albums it represents.
    private func albumsUnder(_ node: CollectionNode) -> [PHAssetCollection] {
        if let album = node.album { return [album] }
        return (node.children ?? []).flatMap { albumsUnder($0) }
    }

    /// A small thumbnail for the list UI.
    func thumbnail(for asset: PHAsset, maxPixel: CGFloat = 240) async -> CGImage? {
        await requestImage(for: asset, targetSize: CGSize(width: maxPixel, height: maxPixel),
                           deliveryMode: .opportunistic)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// JPEG data downscaled for the vision model. ~1024px long edge keeps the
    /// request small and cheap while preserving enough detail for landmarks.
    func jpegForAnalysis(_ asset: PHAsset, maxPixel: CGFloat = 1024, quality: CGFloat = 0.8) async -> Data? {
        guard let image = await requestImage(for: asset,
                                             targetSize: CGSize(width: maxPixel, height: maxPixel),
                                             deliveryMode: .highQualityFormat),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
        else { return nil }
        return jpeg
    }

    /// Write an inferred location back into the asset. Requires the photos
    /// library entitlement + a granted read/write authorization.
    func writeLocation(_ coordinate: CLLocationCoordinate2D, to asset: PHAsset) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest(for: asset)
            request.location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        }
    }

    /// Clear the asset's GPS location.
    func removeLocation(from asset: PHAsset) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest(for: asset)
            request.location = nil
        }
    }

    // MARK: - Private

    private func requestImage(for asset: PHAsset,
                              targetSize: CGSize,
                              deliveryMode: PHImageRequestOptionsDeliveryMode) async -> NSImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = deliveryMode
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true   // pull from iCloud if needed
        options.isSynchronous = false

        return await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestImage(for: asset,
                                                  targetSize: targetSize,
                                                  contentMode: .aspectFit,
                                                  options: options) { image, info in
                // opportunistic delivery can call back twice (thumb, then full);
                // resume once on the first non-degraded (or final) image.
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !resumed && (!isDegraded || image == nil) {
                    resumed = true
                    continuation.resume(returning: image)
                }
            }
        }
    }
}
