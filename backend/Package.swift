// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "KUMarketplace",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", exact: "4.122.3"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.9.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.9.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .systemLibrary(name: "CVips", pkgConfig: "vips", providers: [
            .apt(["libvips-dev", "libheif-plugin-libde265"]), .brew(["vips"])
        ]),
        .target(name: "PhotoDecoder", dependencies: ["CVips"]),
        .executableTarget(name: "Marketplace", dependencies: [
            .target(name: "PhotoDecoder"),
            .product(name: "Vapor", package: "vapor"),
            .product(name: "Fluent", package: "fluent"),
            .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
            .product(name: "Crypto", package: "swift-crypto")
        ]),
        .testTarget(name: "MarketplaceTests", dependencies: [
            .target(name: "Marketplace"),
            .product(name: "VaporTesting", package: "vapor"),
            .product(name: "Fluent", package: "fluent"),
            .product(name: "Crypto", package: "swift-crypto")
        ])
    ]
)
