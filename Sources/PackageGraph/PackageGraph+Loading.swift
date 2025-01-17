//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import OrderedCollections
import PackageLoading
import PackageModel
import TSCBasic

extension PackageGraph {

    /// Load the package graph for the given package path.
    public static func load(
        root: PackageGraphRoot,
        identityResolver: IdentityResolver,
        additionalFileRules: [FileRuleDescription] = [],
        externalManifests: OrderedCollections.OrderedDictionary<PackageIdentity, (manifest: Manifest, fs: FileSystem)>,
        requiredDependencies: Set<PackageReference> = [],
        unsafeAllowedPackages: Set<PackageReference> = [],
        binaryArtifacts: [PackageIdentity: [String: BinaryArtifact]],
        shouldCreateMultipleTestProducts: Bool = false,
        createREPLProduct: Bool = false,
        customPlatformsRegistry: PlatformRegistry? = .none,
        customXCTestMinimumDeploymentTargets: [PackageModel.Platform: PlatformVersion]? = .none,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope
    ) throws -> PackageGraph {

        let observabilityScope = observabilityScope.makeChildScope(description: "Loading Package Graph")

        // Create a map of the manifests, keyed by their identity.
        var manifestMap = externalManifests
        // prefer roots
        root.manifests.forEach {
            manifestMap[$0.key] = ($0.value, fileSystem)
        }
        let successors: (GraphLoadingNode) -> [GraphLoadingNode] = { node in
            node.requiredDependencies().compactMap{ dependency in
                return manifestMap[dependency.identity].map { (manifest, fileSystem) in
                    GraphLoadingNode(identity: dependency.identity, manifest: manifest, productFilter: dependency.productFilter, fileSystem: fileSystem)
                }
            }
        }

        // Construct the root root dependencies set.
        let rootDependencies = Set(root.dependencies.compactMap{
            manifestMap[$0.identity]?.manifest
        })
        let rootManifestNodes = root.packages.map { identity, package in
            GraphLoadingNode(identity: identity, manifest: package.manifest, productFilter: .everything, fileSystem: fileSystem)
        }
        let rootDependencyNodes = root.dependencies.lazy.compactMap { (dependency: PackageDependency) -> GraphLoadingNode? in
            manifestMap[dependency.identity].map {
                GraphLoadingNode(identity: dependency.identity, manifest: $0.manifest, productFilter: dependency.productFilter, fileSystem: $0.fs)
            }
        }
        let inputManifests = rootManifestNodes + rootDependencyNodes

        // Collect the manifests for which we are going to build packages.
        var allNodes: [GraphLoadingNode]

        // Detect cycles in manifest dependencies.
        if let cycle = findCycle(inputManifests, successors: successors) {
            observabilityScope.emit(PackageGraphError.cycleDetected(cycle))
            // Break the cycle so we can build a partial package graph.
            allNodes = inputManifests.filter({ $0.manifest != cycle.cycle[0] })
        } else {
            // Sort all manifests toplogically.
            allNodes = try topologicalSort(inputManifests, successors: successors)
        }

        var flattenedManifests: [PackageIdentity: GraphLoadingNode] = [:]
        for node in allNodes {
            if let existing = flattenedManifests[node.identity] {
                let merged = GraphLoadingNode(
                    identity: node.identity,
                    manifest: node.manifest,
                    productFilter: existing.productFilter.union(node.productFilter),
                    fileSystem: node.fileSystem
                )
                flattenedManifests[node.identity] = merged
            } else {
                flattenedManifests[node.identity] = node
            }
        }
        // sort by identity
        allNodes = flattenedManifests.keys.sorted().map { flattenedManifests[$0]! } // force unwrap fine since we are iterating on keys

        // Create the packages.
        var manifestToPackage: [Manifest: Package] = [:]
        for node in allNodes {
            let nodeObservabilityScope = observabilityScope.makeChildScope(
                description: "loading package \(node.identity)",
                metadata: .packageMetadata(identity: node.identity, kind: node.manifest.packageKind)
            )

            let manifest = node.manifest
            // Derive the path to the package.
            //
            // FIXME: Lift this out of the manifest.
            let packagePath = manifest.path.parentDirectory
            nodeObservabilityScope.trap {
                // Create a package from the manifest and sources.
                let builder = PackageBuilder(
                    identity: node.identity,
                    manifest: manifest,
                    productFilter: node.productFilter,
                    path: packagePath,
                    additionalFileRules: additionalFileRules,
                    binaryArtifacts: binaryArtifacts[node.identity] ?? [:],                
                    shouldCreateMultipleTestProducts: shouldCreateMultipleTestProducts,
                    createREPLProduct: manifest.packageKind.isRoot ? createREPLProduct : false,
                    fileSystem: node.fileSystem,
                    observabilityScope: nodeObservabilityScope
                )
                let package = try builder.construct()
                manifestToPackage[manifest] = package

                // Throw if any of the non-root package is empty.
                if package.targets.isEmpty // System packages have targets in the package but not the manifest.
                    && package.manifest.targets.isEmpty // An unneeded dependency will not have loaded anything from the manifest.
                    && !manifest.packageKind.isRoot {
                    throw PackageGraphError.noModules(package)
                }
            }
        }

        // Resolve dependencies and create resolved packages.
        let resolvedPackages = try createResolvedPackages(
            nodes: allNodes,
            identityResolver: identityResolver,
            manifestToPackage: manifestToPackage,
            rootManifests: root.manifests,
            unsafeAllowedPackages: unsafeAllowedPackages,
            platformRegistry: customPlatformsRegistry ?? .default,
            xcTestMinimumDeploymentTargets: customXCTestMinimumDeploymentTargets ?? MinimumDeploymentTarget.default.xcTestMinimumDeploymentTargets,
            observabilityScope: observabilityScope
        )

        let rootPackages = resolvedPackages.filter{ root.manifests.values.contains($0.manifest) }
        checkAllDependenciesAreUsed(rootPackages, observabilityScope: observabilityScope)

        return try PackageGraph(
            rootPackages: rootPackages,
            rootDependencies: resolvedPackages.filter{ rootDependencies.contains($0.manifest) },
            dependencies: requiredDependencies
        )
    }
}

private func checkAllDependenciesAreUsed(_ rootPackages: [ResolvedPackage], observabilityScope: ObservabilityScope) {
    for package in rootPackages {
        // List all dependency products dependent on by the package targets.
        let productDependencies: Set<ResolvedProduct> = Set(package.targets.flatMap({ target in
            return target.dependencies.compactMap({ targetDependency in
                switch targetDependency {
                case .product(let product, _):
                    return product
                case .target:
                    return nil
                }
            })
        }))

        for dependency in package.dependencies {
            // We continue if the dependency contains executable products to make sure we don't
            // warn on a valid use-case for a lone dependency: swift run dependency executables.
            guard !dependency.products.contains(where: { $0.type == .executable }) else {
                continue
            }
            // Skip this check if this dependency is a system module because system module packages
            // have no products.
            //
            // FIXME: Do/should we print a warning if a dependency has no products?
            if dependency.products.isEmpty && dependency.targets.filter({ $0.type == .systemModule }).count == 1 {
                continue
            }

            // Skip this check if this dependency contains a command plugin product.
            if dependency.products.contains(where: \.isCommandPlugin) {
                continue
            }

            // Otherwise emit a warning if none of the dependency package's products are used.
            let dependencyIsUsed = dependency.products.contains(where: productDependencies.contains)
            if !dependencyIsUsed && !observabilityScope.errorsReportedInAnyScope {
                observabilityScope.emit(.unusedDependency(dependency.identity.description))
            }
        }
    }
}

fileprivate extension ResolvedProduct {
    /// Returns true if and only if the product represents a command plugin target.
    var isCommandPlugin: Bool {
        guard type == .plugin else { return false }
        guard let target = underlyingProduct.targets.compactMap({ $0 as? PluginTarget }).first else { return false }
        guard case .command = target.capability else { return false }
        return true
    }
}

/// Create resolved packages from the loaded packages.
private func createResolvedPackages(
    nodes: [GraphLoadingNode],
    identityResolver: IdentityResolver,
    manifestToPackage: [Manifest: Package],
    // FIXME: This shouldn't be needed once <rdar://problem/33693433> is fixed.
    rootManifests: [PackageIdentity: Manifest],
    unsafeAllowedPackages: Set<PackageReference>,
    platformRegistry: PlatformRegistry,
    xcTestMinimumDeploymentTargets: [PackageModel.Platform: PlatformVersion],
    observabilityScope: ObservabilityScope
) throws -> [ResolvedPackage] {

    // Create package builder objects from the input manifests.
    let packageBuilders: [ResolvedPackageBuilder] = nodes.compactMap{ node in
        guard let package = manifestToPackage[node.manifest] else {
            return nil
        }
        let isAllowedToVendUnsafeProducts = unsafeAllowedPackages.contains{ $0.identity == package.identity }
        
        let allowedToOverride = rootManifests.values.contains(node.manifest)
        return ResolvedPackageBuilder(
            package,
            productFilter: node.productFilter,
            isAllowedToVendUnsafeProducts: isAllowedToVendUnsafeProducts,
            allowedToOverride: allowedToOverride
        )
    }

    // Create a map of package builders keyed by the package identity.
    // This is guaranteed to be unique so we can use spm_createDictionary
    let packagesByIdentity: [PackageIdentity: ResolvedPackageBuilder] = packageBuilders.spm_createDictionary{
        return ($0.package.identity, $0)
    }

    // Resolve module aliases, if specified, for targets and their dependencies
    // across packages. Aliasing will result in target renaming.
    try resolveModuleAliases(packageBuilders: packageBuilders)

    // Scan and validate the dependencies
    for packageBuilder in packageBuilders {
        let package = packageBuilder.package

        let packageObservabilityScope = observabilityScope.makeChildScope(
            description: "Validating package dependencies",
            metadata: package.diagnosticsMetadata
        )
        
        var dependencies = OrderedCollections.OrderedDictionary<PackageIdentity, ResolvedPackageBuilder>()
        var dependenciesByNameForTargetDependencyResolution = [String: ResolvedPackageBuilder]()

        // Establish the manifest-declared package dependencies.
        package.manifest.dependenciesRequired(for: packageBuilder.productFilter).forEach { dependency in
            let dependencyPackageRef = dependency.createPackageRef()

            // Otherwise, look it up by its identity.
            if let resolvedPackage = packagesByIdentity[dependency.identity] {
                // check if this resolved package already listed in the dependencies
                // this means that the dependencies share the same identity
                // FIXME: this works but the way we find out about this is based on a side effect, need to improve it
                guard dependencies[resolvedPackage.package.identity] == nil else {
                    let error = PackageGraphError.dependencyAlreadySatisfiedByIdentifier(
                        package: package.identity.description,
                        dependencyLocation: dependencyPackageRef.locationString,
                        otherDependencyURL: resolvedPackage.package.manifest.packageLocation,
                        identity: dependency.identity)
                    return packageObservabilityScope.emit(error)
                }

                // check if the resolved package location is the same as the dependency one
                // if not, this means that the dependencies share the same identity
                // which only allowed when overriding
                if resolvedPackage.package.manifest.canonicalPackageLocation != dependencyPackageRef.canonicalLocation && !resolvedPackage.allowedToOverride {
                    let error = PackageGraphError.dependencyAlreadySatisfiedByIdentifier(
                        package: package.identity.description,
                        dependencyLocation: dependencyPackageRef.locationString,
                        otherDependencyURL: resolvedPackage.package.manifest.packageLocation,
                        identity: dependency.identity)
                    // 9/2021 this is currently emitting a warning only to support
                    // backwards compatibility with older versions of SwiftPM that had too weak of a validation
                    // we will upgrade this to an error in a few versions to tighten up the validation
                    if dependency.explicitNameForTargetDependencyResolutionOnly == .none ||
                        resolvedPackage.package.manifest.displayName == dependency.explicitNameForTargetDependencyResolutionOnly {
                        packageObservabilityScope.emit(warning: error.description + ". this will be escalated to an error in future versions of SwiftPM.")
                    } else {
                        return packageObservabilityScope.emit(error)
                    }
                } else if resolvedPackage.package.manifest.canonicalPackageLocation == dependencyPackageRef.canonicalLocation &&
                            resolvedPackage.package.manifest.packageLocation != dependencyPackageRef.locationString  &&
                            !resolvedPackage.allowedToOverride {
                    packageObservabilityScope.emit(info: "dependency on '\(resolvedPackage.package.identity)' is represented by similar locations ('\(resolvedPackage.package.manifest.packageLocation)' and '\(dependencyPackageRef.locationString)') which are treated as the same canonical location '\(dependencyPackageRef.canonicalLocation)'.")
                }

                // checks if two dependencies have the same explicit name which can cause target based dependency package lookup issue
                if let explicitDependencyName = dependency.explicitNameForTargetDependencyResolutionOnly {
                    if let previouslyResolvedPackage = dependenciesByNameForTargetDependencyResolution[explicitDependencyName] {
                        let error = PackageGraphError.dependencyAlreadySatisfiedByName(
                            package: package.identity.description,
                            dependencyLocation: dependencyPackageRef.locationString,
                            otherDependencyURL: previouslyResolvedPackage.package.manifest.packageLocation,
                            name: explicitDependencyName)
                        return packageObservabilityScope.emit(error)
                    }
                }

                // checks if two dependencies have the same implicit (identity based) name which can cause target based dependency package lookup issue
                if let previouslyResolvedPackage = dependenciesByNameForTargetDependencyResolution[dependency.identity.description] {
                    let error = PackageGraphError.dependencyAlreadySatisfiedByName(
                        package: package.identity.description,
                        dependencyLocation: dependencyPackageRef.locationString,
                        otherDependencyURL: previouslyResolvedPackage.package.manifest.packageLocation,
                        name: dependency.identity.description)
                    return packageObservabilityScope.emit(error)
                }

                let nameForTargetDependencyResolution = dependency.explicitNameForTargetDependencyResolutionOnly ?? dependency.identity.description
                dependenciesByNameForTargetDependencyResolution[nameForTargetDependencyResolution] = resolvedPackage

                dependencies[resolvedPackage.package.identity] = resolvedPackage
            }
        }

        packageBuilder.dependencies = Array(dependencies.values)

        packageBuilder.defaultLocalization = package.manifest.defaultLocalization

        packageBuilder.platforms = computePlatforms(
            package: package,
            usingXCTest: false,
            platformRegistry: platformRegistry,
            xcTestMinimumDeploymentTargets: xcTestMinimumDeploymentTargets
        )

        let testPlatforms = computePlatforms(
            package: package,
            usingXCTest: true,
            platformRegistry: platformRegistry,
            xcTestMinimumDeploymentTargets: xcTestMinimumDeploymentTargets
        )

        // Create target builders for each target in the package.
        let targetBuilders = package.targets.map{ ResolvedTargetBuilder(target: $0, observabilityScope: observabilityScope) }
        packageBuilder.targets = targetBuilders

        // Establish dependencies between the targets. A target can only depend on another target present in the same package.
        let targetMap = targetBuilders.spm_createDictionary({ ($0.target, $0) })
        for targetBuilder in targetBuilders {
            targetBuilder.dependencies += try targetBuilder.target.dependencies.compactMap { dependency in
                switch dependency {
                case .target(let target, let conditions):
                    guard let targetBuilder = targetMap[target] else {
                        throw InternalError("unknown target \(target.name)")
                    }
                    return .target(targetBuilder, conditions: conditions)
                case .product:
                    return nil
                }
            }
            targetBuilder.defaultLocalization = packageBuilder.defaultLocalization
            targetBuilder.platforms = targetBuilder.target.type == .test ? testPlatforms : packageBuilder.platforms
        }

        // Create product builders for each product in the package. A product can only contain a target present in the same package.
        packageBuilder.products = try package.products.map{
            try ResolvedProductBuilder(product: $0, packageBuilder: packageBuilder, targets: $0.targets.map {
                guard let target = targetMap[$0] else {
                    throw InternalError("unknown target \($0)")
                }
                return target
            })
        }
    }

    // Find duplicate products in the package graph.
    let duplicateProducts = packageBuilders
        .flatMap({ $0.products })
        .map({ $0.product })
        .spm_findDuplicateElements(by: \.name)
        .map({ $0[0].name })

    // Emit diagnostics for duplicate products.
    for productName in duplicateProducts {
        let packages = packageBuilders
            .filter({ $0.products.contains(where: { $0.product.name == productName }) })
            .map{ $0.package.identity.description }
            .sorted()

        observabilityScope.emit(PackageGraphError.duplicateProduct(product: productName, packages: packages))
    }

    // Remove the duplicate products from the builders.
    for packageBuilder in packageBuilders {
        packageBuilder.products = packageBuilder.products.filter({ !duplicateProducts.contains($0.product.name) })
    }

    // The set of all target names.
    var allTargetNames = Set<String>()

    // Track if multiple targets are found with the same name.
    var foundDuplicateTarget = false

    // Do another pass and establish product dependencies of each target.
    for packageBuilder in packageBuilders {
        let package = packageBuilder.package

        let packageObservabilityScope = observabilityScope.makeChildScope(
            description: "Validating package targets",
            metadata: package.diagnosticsMetadata
        )

        // Get all implicit system library dependencies in this package.
        let implicitSystemTargetDeps = packageBuilder.dependencies
            .flatMap({ $0.targets })
            .filter({
                if case let systemLibrary as SystemLibraryTarget = $0.target {
                    return systemLibrary.isImplicit
                }
                return false
            })

        // Get all the products from dependencies of this package.
        let productDependencies = packageBuilder.dependencies
            .flatMap({ (dependency: ResolvedPackageBuilder) -> [ResolvedProductBuilder] in
                // Filter out synthesized products such as tests and implicit executables.
                let explicit = Set(dependency.package.manifest.products.lazy.map({ $0.name }))
                return dependency.products.filter({ explicit.contains($0.product.name) })
            })
        let productDependencyMap = productDependencies.spm_createDictionary({ ($0.product.name, $0) })

        // Establish dependencies in each target.
        for targetBuilder in packageBuilder.targets {
            // Record if we see a duplicate target.
            foundDuplicateTarget = foundDuplicateTarget || !allTargetNames.insert(targetBuilder.target.name).inserted

            // Directly add all the system module dependencies.
            targetBuilder.dependencies += implicitSystemTargetDeps.map { .target($0, conditions: []) }

            // Establish product dependencies.
            for case .product(let productRef, let conditions) in targetBuilder.target.dependencies {
                // Find the product in this package's dependency products.
                guard let product = productDependencyMap[productRef.name] else {
                    // Only emit a diagnostic if there are no other diagnostics.
                    // This avoids flooding the diagnostics with product not
                    // found errors when there are more important errors to
                    // resolve (like authentication issues).
                    if !observabilityScope.errorsReportedInAnyScope {
                        // Emit error if a product (not target) declared in the package is also a productRef (dependency)
                        let declProductsAsDependency = package.products.filter { product in
                            product.name == productRef.name
                        }.map {$0.targets}.flatMap{$0}.filter { t in
                            t.name != productRef.name
                        }

                        let error = PackageGraphError.productDependencyNotFound(
                            package: package.identity.description,
                            targetName: targetBuilder.target.name,
                            dependencyProductName: productRef.name,
                            dependencyPackageName: productRef.package,
                            dependencyProductInDecl: !declProductsAsDependency.isEmpty
                        )
                        packageObservabilityScope.emit(error)
                    }
                    continue
                }

                // Starting in 5.2, and target-based dependency, we require target product dependencies to
                // explicitly reference the package containing the product, or for the product, package and
                // dependency to share the same name. We don't check this in manifest loading for root-packages so
                // we can provide a more detailed diagnostic here.
                if packageBuilder.package.manifest.toolsVersion >= .v5_2 && productRef.package == nil {
                    let referencedPackageIdentity = product.packageBuilder.package.identity
                    guard let referencedPackageDependency = (packageBuilder.package.manifest.dependencies.first { package in
                        return package.identity == referencedPackageIdentity
                    }) else {
                        throw InternalError("dependency reference for \(product.packageBuilder.package.manifest.packageLocation) not found")
                    }
                    let referencedPackageName = referencedPackageDependency.nameForTargetDependencyResolutionOnly
                    if productRef.name !=  referencedPackageName {
                        let error = PackageGraphError.productDependencyMissingPackage(
                            productName: productRef.name,
                            targetName: targetBuilder.target.name,
                            packageIdentifier: referencedPackageName
                        )
                        packageObservabilityScope.emit(error)
                    }
                }

                targetBuilder.dependencies.append(.product(product, conditions: conditions))
            }
        }
    }

    // If a target with similar name was encountered before, we emit a diagnostic.
    if foundDuplicateTarget {
        for targetName in allTargetNames.sorted() {
            // Find the packages this target is present in.
            let packages = packageBuilders
                .filter({ $0.targets.contains(where: { $0.target.name == targetName }) })
                .map{ $0.package.identity.description }
                .sorted()
            if packages.count > 1 {
                observabilityScope.emit(ModuleError.duplicateModule(targetName, packages))
            }
        }
    }
    return try packageBuilders.map{ try $0.construct() }
}

private func computePlatforms(
    package: Package,
    usingXCTest: Bool,
    platformRegistry: PlatformRegistry,
    xcTestMinimumDeploymentTargets: [PackageModel.Platform: PlatformVersion]
) -> SupportedPlatforms {

    // the supported platforms as declared in the manifest
    let declaredPlatforms: [SupportedPlatform] = package.manifest.platforms.map { platform in
        let declaredPlatform = platformRegistry.platformByName[platform.platformName]
            ?? PackageModel.Platform.custom(name: platform.platformName, oldestSupportedVersion: platform.version)
        return SupportedPlatform(
            platform: declaredPlatform,
            version: .init(platform.version),
            options: platform.options
        )
    }

    // the derived platforms based on known minimum deployment target logic
    var derivedPlatforms = [SupportedPlatform]()

    /// Add each declared platform to the supported platforms list.
    for platform in package.manifest.platforms {
        let declaredPlatform = platformRegistry.platformByName[platform.platformName]
            ?? PackageModel.Platform.custom(name: platform.platformName, oldestSupportedVersion: platform.version)
        var version = PlatformVersion(platform.version)

        if usingXCTest, let xcTestMinimumDeploymentTarget = xcTestMinimumDeploymentTargets[declaredPlatform], version < xcTestMinimumDeploymentTarget {
            version = xcTestMinimumDeploymentTarget
        }

        let supportedPlatform = SupportedPlatform(
            platform: declaredPlatform,
            version: version,
            options: platform.options
        )

        derivedPlatforms.append(supportedPlatform)
    }

    // Find the undeclared platforms.
    let remainingPlatforms = Set(platformRegistry.platformByName.keys).subtracting(derivedPlatforms.map({ $0.platform.name }))

    /// Start synthesizing for each undeclared platform.
    for platformName in remainingPlatforms.sorted() {
        let platform = platformRegistry.platformByName[platformName]!

        let oldestSupportedVersion: PlatformVersion
        if usingXCTest, let xcTestMinimumDeploymentTarget = xcTestMinimumDeploymentTargets[platform] {
            oldestSupportedVersion = xcTestMinimumDeploymentTarget
        } else if platform == .macCatalyst, let iOS = derivedPlatforms.first(where: { $0.platform == .iOS }) {
            // If there was no deployment target specified for Mac Catalyst, fall back to the iOS deployment target.
            oldestSupportedVersion = max(platform.oldestSupportedVersion, iOS.version)
        } else {
            oldestSupportedVersion = platform.oldestSupportedVersion
        }

        let supportedPlatform = SupportedPlatform(
            platform: platform,
            version: oldestSupportedVersion,
            options: []
        )

        derivedPlatforms.append(supportedPlatform)
    }

    return SupportedPlatforms(
        declared: declaredPlatforms.sorted(by: { $0.platform.name < $1.platform.name }),
        derived: derivedPlatforms.sorted(by: { $0.platform.name < $1.platform.name })
    )
}

// Track and override module aliases specified for targets in a package graph
private func resolveModuleAliases(packageBuilders: [ResolvedPackageBuilder]) throws {

    // If there are no module aliases specified, return early
    let hasAliases = packageBuilders.contains { $0.package.targets.contains {
            $0.dependencies.contains { dep in
                if case let .product(prodRef, _) = dep {
                    return prodRef.moduleAliases != nil
                }
                return false
            }
        }
    }

    guard hasAliases else { return }
    let aliasTracker = ModuleAliasTracker()
    for packageBuilder in packageBuilders {
        try aliasTracker.addTargetAliases(targets: packageBuilder.package.targets,
                                          package: packageBuilder.package.identity)
    }

    // Track targets that need module aliases for each package
    for packageBuilder in packageBuilders {
        for product in packageBuilder.package.products {
            aliasTracker.trackTargetsPerProduct(product: product,
                                                package: packageBuilder.package.identity)
        }
    }

    // Override module aliases upstream if needed
    aliasTracker.propagateAliases()

    // Validate sources (Swift files only) for modules being aliased.
    // Needs to be done after `propagateAliases` since aliases defined
    // upstream can be overriden.
    for packageBuilder in packageBuilders {
        for product in packageBuilder.package.products {
            try aliasTracker.validateAndApplyAliases(product: product.name,
                                                     package: packageBuilder.package.identity)
        }
    }
}

// This class helps track module aliases in a package graph and override
// upstream alises if needed
private class ModuleAliasTracker {
    var aliasMap = [PackageIdentity: [String: [ModuleAliasModel]]]()
    var idToProductToAllTargets = [PackageIdentity: [String: [Target]]]()
    var productToDirectTargets = [String: [Target]]()
    var productToAllTargets = [String: [Target]]()
    var childToParentProducts = [String: [String]]()
    var parentToChildProducts = [String: [String]]()
    var cachedChildToParentProducts = [String: [String]]()
    var parentToChildIDs = [PackageIdentity: [PackageIdentity]]()
    var childToParentID = [PackageIdentity: PackageIdentity]()

    init() {}
    func addTargetAliases(targets: [Target], package: PackageIdentity) throws {
        let targetDependencies = targets.map{$0.dependencies}.flatMap{$0}
        for dep in targetDependencies {
            if case let .product(productRef, _) = dep,
               let productPkg = productRef.package {
                let productPkgID = PackageIdentity.plain(productPkg)
                // Track dependency package ID chain
                addPackageIDChain(parent: package, child: productPkgID)
                if let aliasList = productRef.moduleAliases {
                    // Track aliases for this product
                    try addAliases(aliasList,
                                   product: productRef.name,
                                   originPackage: productPkgID,
                                   consumingPackage: package)
                }
            }
        }
    }

    func addAliases(_ aliases: [String: String],
                    product: String,
                    originPackage: PackageIdentity,
                    consumingPackage: PackageIdentity) throws {
        if let aliasDict = aliasMap[originPackage] {
            let existingAliases = aliasDict.values.flatMap{$0}.filter {  aliases.keys.contains($0.name) }
            for existingAlias in existingAliases {
                if let newAlias = aliases[existingAlias.name], newAlias != existingAlias.alias {
                    // Error if there are multiple different aliases specified for
                    // targets in this product
                    throw PackageGraphError.multipleModuleAliases(target: existingAlias.name, product: product, package: originPackage.description, aliases: existingAliases.map{$0.alias} + [newAlias])
                }
            }
        }

        for (originalName, newName) in aliases {
            let model = ModuleAliasModel(name: originalName, alias: newName, originPackage: originPackage, consumingPackage: consumingPackage)
            aliasMap[originPackage, default: [:]][product, default: []].append(model)
        }
    }

    func addPackageIDChain(parent: PackageIdentity,
                           child: PackageIdentity) {
        if parentToChildIDs[parent]?.contains(child) ?? false {
            // Already added
        } else {
            parentToChildIDs[parent, default: []].append(child)
            // Used to track the top-most level package
            childToParentID[child] = parent
        }
    }

    // This func should be called once per product
    func trackTargetsPerProduct(product: Product,
                                package: PackageIdentity) {
        let targetDeps = product.targets.map{$0.dependencies}.flatMap{$0}
        var allTargetDeps = product.targets.map{$0.dependentTargets().map{$0.dependencies}}.flatMap{$0}.flatMap{$0}
        allTargetDeps.append(contentsOf: targetDeps)
        for dep in allTargetDeps {
            if case let .product(depRef, _) = dep {
                childToParentProducts[depRef.name, default: []].append(product.name)
                parentToChildProducts[product.name, default: []].append(depRef.name)
            }
        }

        var allTargetsInProduct = targetDeps.compactMap{$0.target}
        allTargetsInProduct.append(contentsOf: product.targets)
        idToProductToAllTargets[package, default: [:]][product.name] = allTargetsInProduct
        productToDirectTargets[product.name] = product.targets
        productToAllTargets[product.name] = allTargetsInProduct
    }

    func validateAndApplyAliases(product: String,
                                 package: PackageIdentity) throws {
        guard let targets = idToProductToAllTargets[package]?[product] else { return }
        let targetsWithAliases = targets.filter{ $0.moduleAliases != nil }
        for target in targetsWithAliases {
            if target.sources.containsNonSwiftFiles {
                throw PackageGraphError.invalidSourcesForModuleAliasing(target: target.name, product: product, package: package.description)
            }
            target.applyAlias()
        }
    }

    func propagateAliases() {
        // First get the root package ID
        var pkgID = childToParentID.first?.key
        var rootPkg = pkgID
        while pkgID != nil {
            rootPkg = pkgID
            // pkgID is not nil here so can be force unwrapped
            pkgID = childToParentID[pkgID!]
        }
        guard let rootPkg = rootPkg else { return }
        // Propagate and override upstream aliases if needed
        var aliasBuffer = [String: ModuleAliasModel]()
        propagate(package: rootPkg, aliasBuffer: &aliasBuffer)
        // Now merge overriden upstream aliases and add them to
        // downstream targets
        if let productToAllTargets = idToProductToAllTargets[rootPkg] {
            for productName in productToAllTargets.keys {
                mergeAliases(product: productName)
            }
        }
    }

    // Traverse upstream and override aliases for the same targets if needed
    func propagate(package: PackageIdentity, aliasBuffer: inout [String: ModuleAliasModel]) {
        if let curProductToTargetAliases = aliasMap[package] {
            let curAliasModels = curProductToTargetAliases.map {$0.value}.filter{!$0.isEmpty}.flatMap{$0}
            for aliasModel in curAliasModels {
                // A buffer is used to track the most downstream aliases
                // (hence the nil check here) to allow overriding upstream
                // aliases for targets; if the downstream aliases are applied
                // to upstream targets, then they get removed
                if aliasBuffer[aliasModel.name] == nil {
                    // Add a target name as a key. The buffer only tracks
                    // a target that needs to be renamed, not the depending
                    // targets which might have multiple target dependencies
                    // with their aliases, so add a single alias model as value.
                    aliasBuffer[aliasModel.name] = aliasModel
                }
            }
        }
        if let curProductToTargets = idToProductToAllTargets[package] {
            // Check if targets for the products in this package have
            // aliases tracked by the buffer
            let curProductToTargetsToAlias = curProductToTargets.filter { $0.value.contains { aliasBuffer[$0.name] != nil } }
            if !curProductToTargetsToAlias.isEmpty {
                var usedKeys = Set<String>()
                for (curProductName, targetsForCurProduct) in curProductToTargets {
                    if let targetListToAlias = curProductToTargetsToAlias[curProductName] {
                        for targetToAlias in targetListToAlias {
                            if let aliasModel = aliasBuffer[targetToAlias.name] {
                                var didAlias = false
                                for curTarget in targetsForCurProduct {
                                    // Check if curTarget is relevant for aliasing
                                    let canAlias = curTarget.name == aliasModel.name || curTarget.dependencies.contains { $0.name == aliasModel.name }
                                    if canAlias {
                                        curTarget.addModuleAlias(for: aliasModel.name, as: aliasModel.alias)
                                        didAlias = true
                                    }
                                }
                                if didAlias {
                                    usedKeys.insert(targetToAlias.name)
                                }
                            }
                        }
                    }
                }
                for used in usedKeys {
                    // Remove an entry for a used alias
                    aliasBuffer.removeValue(forKey: used)
                }
            }
        }
        guard let children = parentToChildIDs[package] else { return }
        for childID in children {
            propagate(package: childID, aliasBuffer: &aliasBuffer)
        }
    }

    // Merge overriden upstream aliases and add them to downstream targets
    func mergeAliases(product: String) {
        guard let childProducts = parentToChildProducts[product] else { return }
        for child in childProducts {
            mergeAliases(product: child)
            // Filter out targets in the current product with names that are
            // aliased with different values in the child products since they
            // should either not be aliased or their existing aliases if any
            // should not be overridden.
            let allTargetNamesInCurProduct = productToAllTargets[product]?.compactMap{$0.name} ?? []
            let childTargetsAliases = productToDirectTargets[child]?.compactMap{$0.moduleAliases}.flatMap{$0}.filter{ !allTargetNamesInCurProduct.contains($0.key) }

            if let childTargetsAliases = childTargetsAliases,
               let directTargets = productToDirectTargets[product] {
                // Keep track of all targets in this product that directly
                // or indirectly depend on the child product
                let directRelevantTargets = directTargets.filter {$0.dependsOn(product: child)}
                var relevantTargets = directTargets.map{$0.dependentTargets()}.flatMap{$0}.filter {$0.dependsOn(product: child)}
                relevantTargets.append(contentsOf: directTargets)
                relevantTargets.append(contentsOf: directRelevantTargets)
                let relevantTargetSet = Set(relevantTargets)

                // Used to compare with aliases defined in other child products
                // and detect a conflict if any.
                let allTargetsInOtherChildProducts = childProducts.filter{$0 != child }.compactMap{productToAllTargets[$0]}.flatMap{$0}
                let allTargetNamesInChildProduct = productToAllTargets[child]?.map{$0.name} ?? []
                for curTarget in relevantTargetSet {
                    for (nameToBeAliased, aliasInChild) in childTargetsAliases {
                        // If there are targets in other child products that
                        // have the same name that's being aliased here, but
                        // targets in this child product don't, we need to use
                        // alias values of those targets as they take a precedence
                        let otherAliasesInChildProducts = allTargetsInOtherChildProducts.filter{$0.name == nameToBeAliased}.compactMap{$0.moduleAliases}.flatMap{$0}.filter{$0.key == nameToBeAliased}
                        if !otherAliasesInChildProducts.isEmpty,
                           !allTargetNamesInChildProduct.contains(curTarget.name) {
                            for (aliasKey, aliasValue) in otherAliasesInChildProducts {
                                // Reset the old alias value with this aliasValue
                                if curTarget.moduleAliases?[aliasKey] != aliasValue {
                                    curTarget.addModuleAlias(for: aliasKey, as: aliasValue)
                                }
                            }
                        } else {
                            // If there are multiple aliases for the same key from
                            // different child products, and their values are
                            // different, aliasing should not be applied.
                            let hasMultiValuesForAliasing = allTargetsInOtherChildProducts.compactMap{$0.moduleAliases}.flatMap{$0}.contains{$0.key == nameToBeAliased && $0.value != aliasInChild}
                            if hasMultiValuesForAliasing {
                                // If there are aliases, remove as aliasing should
                                // not be applied
                                curTarget.removeModuleAlias(for: nameToBeAliased)
                            } else if curTarget.moduleAliases?[nameToBeAliased] == nil {
                                // Otherwise add the alias if none exists
                                curTarget.addModuleAlias(for: nameToBeAliased, as: aliasInChild)
                            }
                        }
                    }
                }
            }
        }
    }
}

// Used to keep track of module alias info for each package
private class ModuleAliasModel {
    let name: String
    var alias: String
    let originPackage: PackageIdentity
    let consumingPackage: PackageIdentity

    init(name: String, alias: String, originPackage: PackageIdentity, consumingPackage: PackageIdentity) {
        self.name = name
        self.alias = alias
        self.originPackage = originPackage
        self.consumingPackage = consumingPackage
    }
}

private extension Target {
    func dependsOn(product: String) -> Bool {
        return dependencies.contains { dep in
            if case let .product(prodRef, _) = dep {
                return prodRef.name == product
            }
            return false
        }
    }

    func dependentTargets() -> [Target] {
        return dependencies.compactMap{$0.target}
    }
}

/// A generic builder for `Resolved` models.
private class ResolvedBuilder<T> {
    /// The constructed object, available after the first call to `construct()`.
    private var _constructedObject: T?

    /// Construct the object with the accumulated data.
    ///
    /// Note that once the object is constructed, future calls to
    /// this method will return the same object.
    final func construct() throws -> T {
        if let constructedObject = _constructedObject {
            return constructedObject
        }
        let constructedObject = try self.constructImpl()
        _constructedObject = constructedObject
        return constructedObject
    }

    /// The object construction implementation.
    func constructImpl() throws -> T {
        fatalError("Should be implemented by subclasses")
    }
}

/// Builder for resolved product.
private final class ResolvedProductBuilder: ResolvedBuilder<ResolvedProduct> {
    /// The reference to its package.
    unowned let packageBuilder: ResolvedPackageBuilder

    /// The product reference.
    let product: Product

    /// The target builders in the product.
    let targets: [ResolvedTargetBuilder]

    init(product: Product, packageBuilder: ResolvedPackageBuilder, targets: [ResolvedTargetBuilder]) {
        self.product = product
        self.packageBuilder = packageBuilder
        self.targets = targets
    }

    override func constructImpl() throws -> ResolvedProduct {
        return ResolvedProduct(
            product: product,
            targets: try targets.map{ try $0.construct() }
        )
    }
}

/// Builder for resolved target.
private final class ResolvedTargetBuilder: ResolvedBuilder<ResolvedTarget> {

    /// Enumeration to represent target dependencies.
    enum Dependency {

        /// Dependency to another target, with conditions.
        case target(_ target: ResolvedTargetBuilder, conditions: [PackageConditionProtocol])

        /// Dependency to a product, with conditions.
        case product(_ product: ResolvedProductBuilder, conditions: [PackageConditionProtocol])
    }

    /// The target reference.
    let target: Target

    /// DiagnosticsEmitter with which to emit diagnostics
    let diagnosticsEmitter: DiagnosticsEmitter

    /// The target dependencies of this target.
    var dependencies: [Dependency] = []

    /// The defaultLocalization for this package
    var defaultLocalization: String? = nil

    /// The platforms supported by this package.
    var platforms: SupportedPlatforms = .init(declared: [], derived: [])

    init(
        target: Target,
        observabilityScope: ObservabilityScope
    ) {
        self.target = target
        self.diagnosticsEmitter = observabilityScope.makeDiagnosticsEmitter() {
            var metadata = ObservabilityMetadata()
            metadata.targetName = target.name
            return metadata
        }
    }

    func diagnoseInvalidUseOfUnsafeFlags(_ product: ResolvedProduct) throws {
        // Diagnose if any target in this product uses an unsafe flag.
        for target in try product.recursiveTargetDependencies() {
            for (decl, assignments) in target.underlyingTarget.buildSettings.assignments {
                let flags = assignments.flatMap(\.values)
                if BuildSettings.Declaration.unsafeSettings.contains(decl) && !flags.isEmpty {
                    self.diagnosticsEmitter.emit(.productUsesUnsafeFlags(product: product.name, target: target.name))
                    break
                }
            }
        }
    }

    override func constructImpl() throws -> ResolvedTarget {
        let dependencies = try self.dependencies.map { dependency -> ResolvedTarget.Dependency in
            switch dependency {
            case .target(let targetBuilder, let conditions):
                return .target(try targetBuilder.construct(), conditions: conditions)
            case .product(let productBuilder, let conditions):
                let product = try productBuilder.construct()
                if !productBuilder.packageBuilder.isAllowedToVendUnsafeProducts {
                    try self.diagnoseInvalidUseOfUnsafeFlags(product)
                }
                return .product(product, conditions: conditions)
            }
        }

        return ResolvedTarget(
            target: self.target,
            dependencies: dependencies,
            defaultLocalization: self.defaultLocalization,
            platforms: self.platforms
        )
    }
}

/// Builder for resolved package.
private final class ResolvedPackageBuilder: ResolvedBuilder<ResolvedPackage> {

    /// The package reference.
    let package: Package

    /// The product filter applied to the package.
    let productFilter: ProductFilter

    /// Package can vend unsafe products
    let isAllowedToVendUnsafeProducts: Bool

    /// Package can be overridden
    let allowedToOverride: Bool

    /// The targets in the package.
    var targets: [ResolvedTargetBuilder] = []

    /// The products in this package.
    var products: [ResolvedProductBuilder] = []

    /// The dependencies of this package.
    var dependencies: [ResolvedPackageBuilder] = []

    /// The defaultLocalization for this package.
    var defaultLocalization: String? = nil

    /// The platforms supported by this package.
    var platforms: SupportedPlatforms = .init(declared: [], derived: [])

    init(_ package: Package, productFilter: ProductFilter, isAllowedToVendUnsafeProducts: Bool, allowedToOverride: Bool) {
        self.package = package
        self.productFilter = productFilter
        self.isAllowedToVendUnsafeProducts = isAllowedToVendUnsafeProducts
        self.allowedToOverride = allowedToOverride
    }

    override func constructImpl() throws -> ResolvedPackage {
        return ResolvedPackage(
            package: self.package,
            defaultLocalization: self.defaultLocalization,
            platforms: self.platforms,
            dependencies: try self.dependencies.map{ try $0.construct() },
            targets: try self.targets.map{ try $0.construct() },
            products: try self.products.map{ try $0.construct() }
        )
    }
}

/// Finds the first cycle encountered in a graph.
///
/// This is different from the one in tools support core, in that it handles equality separately from node traversal. Nodes traverse product filters, but only the manifests must be equal for there to be a cycle.
fileprivate func findCycle(
    _ nodes: [GraphLoadingNode],
    successors: (GraphLoadingNode) throws -> [GraphLoadingNode]
) rethrows -> (path: [Manifest], cycle: [Manifest])? {
    // Ordered set to hold the current traversed path.
    var path = OrderedCollections.OrderedSet<Manifest>()

    // Function to visit nodes recursively.
    // FIXME: Convert to stack.
    func visit(
      _ node: GraphLoadingNode,
      _ successors: (GraphLoadingNode) throws -> [GraphLoadingNode]
    ) rethrows -> (path: [Manifest], cycle: [Manifest])? {
        // If this node is already in the current path then we have found a cycle.
        if !path.append(node.manifest).inserted {
            let index = path.firstIndex(of: node.manifest)! // forced unwrap safe
            return (Array(path[path.startIndex..<index]), Array(path[index..<path.endIndex]))
        }

        for succ in try successors(node) {
            if let cycle = try visit(succ, successors) {
                return cycle
            }
        }
        // No cycle found for this node, remove it from the path.
        let item = path.removeLast()
        assert(item == node.manifest)
        return nil
    }

    for node in nodes {
        if let cycle = try visit(node, successors) {
            return cycle
        }
    }
    // Couldn't find any cycle in the graph.
    return nil
}
