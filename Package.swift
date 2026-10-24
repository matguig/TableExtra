// swift-tools-version:6.0
import PackageDescription

let libpqLib = "/opt/homebrew/opt/libpq/lib"
let libssh2Lib = "/opt/homebrew/opt/libssh2/lib"

let package = Package(
    name: "TableExtra",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TableExtra", targets: ["TableExtra"]),
        .executable(name: "tableextra-mcp", targets: ["tableextra-mcp"]),
        .library(name: "MTPCore", targets: ["MTPCore"]),
    ],
    dependencies: [
        // RDS / CloudWatch / Performance Insights for the AWS RDS screen (read-only calls).
        .package(url: "https://github.com/awslabs/aws-sdk-swift.git", exact: "1.8.14"),
    ],
    targets: [
        .systemLibrary(name: "CLibPQ", path: "Sources/CLibPQ"),
        .systemLibrary(name: "CLibSSH2", path: "Sources/CLibSSH2"),
        .target(
            name: "MTPCore",
            dependencies: ["CLibPQ", "CLibSSH2"],
            path: "Sources/MTPCore",
            linkerSettings: [
                .unsafeFlags(["-L\(libpqLib)", "-L\(libssh2Lib)"]),
                .linkedLibrary("sqlite3"),
                .linkedFramework("Security"),
                .linkedFramework("LocalAuthentication"),
            ]
        ),
        .target(name: "MTPUIKit", dependencies: ["MTPCore"], path: "Sources/MTPUIKit"),
        .target(
            name: "FeatureInsights",
            dependencies: [
                "MTPCore", "MTPUIKit",
                .product(name: "AWSRDS", package: "aws-sdk-swift"),
                .product(name: "AWSCloudWatch", package: "aws-sdk-swift"),
                .product(name: "AWSPI", package: "aws-sdk-swift"),
                .product(name: "AWSSTS", package: "aws-sdk-swift"),
            ],
            path: "Sources/FeatureInsights"
        ),
        .target(name: "FeatureSchemaTools", dependencies: ["MTPCore", "MTPUIKit"], path: "Sources/FeatureSchemaTools"),
        .target(name: "FeatureDataTransfer", dependencies: ["MTPCore", "MTPUIKit"], path: "Sources/FeatureDataTransfer"),
        // tableextra-mcp's read-only database tools, shared with the in-app assistant (API backend).
        .target(name: "MTPAgentTools", dependencies: ["MTPCore"], path: "Sources/MTPAgentTools"),
        .target(name: "FeatureAI", dependencies: ["MTPCore", "MTPUIKit", "MTPAgentTools"], path: "Sources/FeatureAI"),
        .executableTarget(
            name: "TableExtra",
            dependencies: ["MTPCore", "MTPUIKit", "FeatureInsights", "FeatureSchemaTools", "FeatureDataTransfer", "FeatureAI"],
            path: "Sources/TableExtra"
        ),
        .executableTarget(name: "tableextra-mcp", dependencies: ["MTPCore", "MTPAgentTools"], path: "Sources/tableextra-mcp"),
        .testTarget(name: "MTPCoreTests", dependencies: ["MTPCore"], path: "Tests/MTPCoreTests"),
        .testTarget(name: "FeatureInsightsTests", dependencies: ["FeatureInsights"], path: "Tests/FeatureInsightsTests"),
        .testTarget(name: "FeatureSchemaToolsTests", dependencies: ["FeatureSchemaTools"], path: "Tests/FeatureSchemaToolsTests"),
        .testTarget(name: "FeatureDataTransferTests", dependencies: ["FeatureDataTransfer"], path: "Tests/FeatureDataTransferTests"),
        .testTarget(name: "FeatureAITests", dependencies: ["FeatureAI", "MTPAgentTools"], path: "Tests/FeatureAITests"),
        .testTarget(name: "MCPServerTests", dependencies: ["tableextra-mcp", "MTPAgentTools", "MTPCore"], path: "Tests/MCPServerTests", exclude: ["e2e.sh"]),
    ],
    swiftLanguageModes: [.v5]
)
