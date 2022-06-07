// swift-tools-version:5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swiftHelper",
    dependencies: [
        .package(url: "https://github.com/Kitura/BlueSocket.git", from: "2.0.2")
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .executableTarget(
            name: "swiftHelper",
            dependencies: [
                .product(name: "Socket", package: "BlueSocket")
            ])
    ]
)
