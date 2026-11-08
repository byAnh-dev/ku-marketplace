// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "KUMarketplace",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/vapor/vapor.git", exact: "4.122.3")],
    targets: [
        .executableTarget(name: "Marketplace", dependencies: [.product(name: "Vapor", package: "vapor")]),
        .testTarget(name: "MarketplaceTests", dependencies: [
            .target(name: "Marketplace"),
            .product(name: "VaporTesting", package: "vapor")
        ])
    ]
)
