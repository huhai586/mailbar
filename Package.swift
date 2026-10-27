// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Mail",
    platforms: [.macOS(.v13)],
    products: [
        // 供 Xcode 里的 App 工程引用
        .library(name: "MailCore", targets: ["MailCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        // GitHub 官方的 Markdown 解析器（表格、删除线、任务列表、自动链接），用来渲染 GitHub 评论和 Markdown 格式的邮件
        .package(url: "https://github.com/swiftlang/swift-cmark.git", branch: "gfm"),
    ],
    targets: [
        .target(
            name: "MailCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ],
            path: "Sources/MailCore"
        ),
        .executableTarget(name: "mailsync", dependencies: ["MailCore"], path: "Sources/mailsync"),
        .testTarget(name: "MailCoreTests", dependencies: ["MailCore"], path: "Tests/MailCoreTests"),
    ]
)
