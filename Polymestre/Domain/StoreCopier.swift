import CoreData
import Foundation

/// Recopie une base dans une autre, **par identifiant**, sans rien perdre ni doubler.
///
/// Sert au changement d'identité de l'app (StudyTrack → Polymestre) : la base de
/// l'ancien conteneur iCloud est relue et recopiée dans le nouveau. Travaille au
/// niveau de Core Data pour être **générique** : chaque entité, chaque attribut
/// (y compris les données externes et les attributs composés), chaque relation —
/// sans liste de champs à tenir à jour.
///
/// Règles :
///   • un objet dont l'`id` existe déjà dans la destination n'est **pas réécrit** :
///     la copie est rejouable (une seconde passe ne copie que ce qui manque) ;
///   • les relations d'un objet copié pointent vers les objets de même `id` dans
///     la destination, qu'ils viennent d'être copiés ou qu'ils y fussent déjà
///     (Core Data tient l'inverse : un objet présent retrouve un lien vers un objet recopié) ;
///   • la source n'est jamais modifiée (le contexte source n'est jamais enregistré).
///
/// **Doublons de la source.** Une base synchronisée peut contenir plusieurs objets de
/// même `id` (constaté : des sessions et des sous-questions arrivées deux fois). Ils
/// deviennent **un seul** objet, fusionné sans perte : un champ vide d'un côté prend la
/// valeur de l'autre, les relations « vers plusieurs » se réunissent. Deux valeurs
/// différentes pour le même champ sont un **conflit** : la première est gardée, et le
/// conflit est rapporté (jamais tu).
///
/// Une entité sans attribut `id` n'est recopiée que si la destination n'en a
/// aucune (on ne saurait pas reconnaître un doublon).
enum StoreCopier {

    struct EntityCount: Equatable {
        /// Objets lus dans la source (doublons compris).
        var source = 0
        /// Identifiants distincts dans la source.
        var unique = 0
        var copied = 0
        var alreadyThere = 0
        /// Objets de la source fondus dans un autre de même `id`.
        var mergedDuplicates = 0
    }

    struct Conflict: Equatable {
        var entity: String
        var id: UUID
        var key: String
    }

    struct Report: Equatable {
        var entities: [String: EntityCount] = [:]
        var conflicts: [Conflict] = []
        var copied: Int { entities.values.reduce(0) { $0 + $1.copied } }
        var source: Int { entities.values.reduce(0) { $0 + $1.source } }
        var unique: Int { entities.values.reduce(0) { $0 + $1.unique } }
        var mergedDuplicates: Int { entities.values.reduce(0) { $0 + $1.mergedDuplicates } }
        var summary: String {
            var parts = entities.sorted { $0.key < $1.key }.filter { $0.value.source > 0 }.map { name, c in
                "\(name) \(c.copied)/\(c.unique)" + (c.mergedDuplicates > 0 ? String(localized: " (+\(c.mergedDuplicates) doublons fondus)") : "")
            }
            if !conflicts.isEmpty { parts.append("\(conflicts.count) conflits") }
            return parts.joined(separator: " · ")
        }
    }

    static let idKey = "id"

    /// Copie dans `destination` tout ce qui y manque, puis enregistre `destination`.
    ///
    /// `only` limite la copie à ces identifiants (les autres objets de la source servent
    /// seulement à relier : un objet copié pointe vers l'objet de même `id` déjà présent
    /// dans la destination). Les entités sans `id` ne sont alors pas copiées.
    ///
    /// Les deux contextes doivent être utilisés depuis le fil qui appelle (contextes
    /// privés : appeler à l'intérieur de `performAndWait`, ou contextes du fil principal).
    static func copyMissing(from source: NSManagedObjectContext, to destination: NSManagedObjectContext,
                            only: Set<UUID>? = nil) throws -> Report {
        guard let sourceModel = source.persistentStoreCoordinator?.managedObjectModel,
              let destinationModel = destination.persistentStoreCoordinator?.managedObjectModel else {
            throw CopyError.noCoordinator
        }
        var report = Report()
        // Objet source (par son ObjectID) → objet de la destination.
        var mapped: [NSManagedObjectID: NSManagedObject] = [:]
        // Objets créés, avec **tous** leurs originaux (doublons compris) : seuls eux
        // reçoivent leurs relations — les objets déjà présents ne sont pas réécrits.
        var created: [(originals: [NSManagedObject], copy: NSManagedObject, id: UUID?)] = []
        // Relations « vers un » sur lesquelles les copies d'un même objet ne s'accordent pas.
        var undecided: [(copy: NSManagedObject, key: String, candidates: [NSManagedObject], id: UUID?)] = []

        let entities = destinationModel.entities.filter { !$0.isAbstract }.sorted { ($0.name ?? "") < ($1.name ?? "") }
        for destinationEntity in entities {
            guard let name = destinationEntity.name,
                  let sourceEntity = sourceModel.entitiesByName[name] else { continue }
            let sourceObjects = try fetchAll(sourceEntity, in: source)
            var count = EntityCount(source: sourceObjects.count)
            let hasID = destinationEntity.attributesByName[idKey] != nil && sourceEntity.attributesByName[idKey] != nil
            if hasID {
                var existing: [UUID: NSManagedObject] = [:]
                for object in try fetchAll(destinationEntity, in: destination) {
                    if let id = object.value(forKey: idKey) as? UUID { existing[id] = object }
                }
                // Les objets de la source, groupés par `id`, dans l'ordre de lecture.
                var order: [UUID] = []
                var groups: [UUID: [NSManagedObject]] = [:]
                for object in sourceObjects {
                    guard let id = object.value(forKey: idKey) as? UUID else { continue }
                    if groups[id] == nil { order.append(id) }
                    groups[id, default: []].append(object)
                }
                count.unique = order.count
                for id in order {
                    let group = groups[id]!
                    count.mergedDuplicates += group.count - 1
                    if let already = existing[id] {
                        for object in group { mapped[object.objectID] = already }
                        count.alreadyThere += 1
                    } else if let only, !only.contains(id) {
                        continue  // pas à cet appareil de le copier
                    } else {
                        let copy = insertCopy(of: group, entity: destinationEntity, into: destination,
                                              id: id, conflicts: &report.conflicts)
                        existing[id] = copy
                        for object in group { mapped[object.objectID] = copy }
                        created.append((group, copy, id))
                        count.copied += 1
                    }
                }
            } else if only == nil, try destination.count(for: request(destinationEntity)) == 0 {
                count.unique = sourceObjects.count
                for object in sourceObjects {
                    let copy = insertCopy(of: [object], entity: destinationEntity, into: destination,
                                          id: nil, conflicts: &report.conflicts)
                    mapped[object.objectID] = copy
                    created.append(([object], copy, nil))
                    count.copied += 1
                }
            } else {
                count.unique = sourceObjects.count
                count.alreadyThere = sourceObjects.count
            }
            report.entities[name] = count
        }

        // Les relations, une fois tous les objets connus.
        for (originals, copy, id) in created {
            for (name, relationship) in copy.entity.relationshipsByName {
                let sources = originals.filter { $0.entity.relationshipsByName[name] != nil }
                guard !sources.isEmpty else { continue }
                if relationship.isToMany {
                    // Réunion, sans doublon, dans l'ordre du premier original.
                    var seen = Set<NSManagedObjectID>()
                    var targets: [NSManagedObject] = []
                    for original in sources {
                        for target in members(original.value(forKey: name)) {
                            guard let copyTarget = mapped[target.objectID], seen.insert(copyTarget.objectID).inserted else { continue }
                            targets.append(copyTarget)
                        }
                    }
                    if relationship.isOrdered {
                        copy.setValue(NSOrderedSet(array: targets), forKey: name)
                    } else {
                        copy.setValue(NSSet(array: targets), forKey: name)
                    }
                } else {
                    let candidates = sources.compactMap { ($0.value(forKey: name) as? NSManagedObject).flatMap { mapped[$0.objectID] } }
                    let distinct = candidates.reduce(into: [NSManagedObject]()) { acc, t in
                        if !acc.contains(where: { $0.objectID == t.objectID }) { acc.append(t) }
                    }
                    if distinct.count > 1 {
                        // Décidé après les autres relations : voir plus bas.
                        undecided.append((copy, name, distinct, id))
                    } else {
                        copy.setValue(distinct.first, forKey: name)
                    }
                }
            }
        }

        // Deux copies d'un même objet pointent vers deux objets différents (constaté :
        // une sous-question rattachée à une question d'un **autre** exercice). La cible
        // gardée est celle qui partage le plus de liens avec l'objet (la question du
        // même exercice) ; à égalité, la première. Le conflit est rapporté.
        for (copy, name, candidates, id) in undecided {
            let toOne = copy.entity.relationshipsByName.filter { !$0.value.isToMany && $0.key != name }.map(\.key)
            func shared(_ candidate: NSManagedObject) -> Int {
                toOne.filter { key in
                    guard candidate.entity.relationshipsByName[key] != nil,
                          let mine = copy.value(forKey: key) as? NSManagedObject,
                          let theirs = candidate.value(forKey: key) as? NSManagedObject else { return false }
                    return mine.objectID == theirs.objectID
                }.count
            }
            let best = candidates.enumerated().max { a, b in
                let (sa, sb) = (shared(a.element), shared(b.element))
                return sa != sb ? sa < sb : a.offset > b.offset
            }?.element
            copy.setValue(best, forKey: name)
            if let id, let entity = copy.entity.name {
                report.conflicts.append(Conflict(entity: entity, id: id, key: name))
            }
        }

        if destination.hasChanges { try destination.save() }
        return report
    }

    /// Les identifiants présents dans la source et absents de la destination, par entité.
    ///
    /// Vide quand la copie est complète. Les entités sans `id` sont comparées par nombre
    /// (une entité de la source plus nombreuse que dans la destination y figure avec
    /// une liste vide).
    static func missing(from source: NSManagedObjectContext, in destination: NSManagedObjectContext) throws -> [String: [UUID]] {
        guard let sourceModel = source.persistentStoreCoordinator?.managedObjectModel,
              let destinationModel = destination.persistentStoreCoordinator?.managedObjectModel else {
            throw CopyError.noCoordinator
        }
        var out: [String: [UUID]] = [:]
        for destinationEntity in destinationModel.entities where !destinationEntity.isAbstract {
            guard let name = destinationEntity.name, let sourceEntity = sourceModel.entitiesByName[name] else { continue }
            if destinationEntity.attributesByName[idKey] != nil, sourceEntity.attributesByName[idKey] != nil {
                let have = Set(try ids(destinationEntity, in: destination))
                let lacking = Set(try ids(sourceEntity, in: source)).filter { !have.contains($0) }
                if !lacking.isEmpty { out[name] = lacking.sorted { $0.uuidString < $1.uuidString } }
            } else if try source.count(for: request(sourceEntity)) > destination.count(for: request(destinationEntity)) {
                out[name] = []
            }
        }
        return out
    }

    /// Par entité : le nombre d'identifiants **distincts** (les objets sans `id` comptent un par un).
    ///
    /// C'est la mesure à comparer entre l'ancienne base et la nouvelle : des doublons
    /// fondus ne sont pas une perte.
    static func uniqueCounts(in context: NSManagedObjectContext) throws -> [String: Int] {
        guard let model = context.persistentStoreCoordinator?.managedObjectModel else { throw CopyError.noCoordinator }
        var out: [String: Int] = [:]
        for entity in model.entities where !entity.isAbstract {
            guard let name = entity.name else { continue }
            out[name] = entity.attributesByName[idKey] != nil
                ? Set(try ids(entity, in: context)).count
                : try context.count(for: request(entity))
        }
        return out
    }

    /// Tous les identifiants de la base, toutes entités confondues (des UUID aléatoires :
    /// deux entités ne se les partagent pas).
    static func allIDs(in context: NSManagedObjectContext) throws -> Set<UUID> {
        guard let model = context.persistentStoreCoordinator?.managedObjectModel else { throw CopyError.noCoordinator }
        var out = Set<UUID>()
        for entity in model.entities where !entity.isAbstract && entity.attributesByName[idKey] != nil {
            out.formUnion(try ids(entity, in: context))
        }
        return out
    }

    /// Le nombre d'objets par entité, doublons compris.
    static func counts(in context: NSManagedObjectContext) throws -> [String: Int] {
        guard let model = context.persistentStoreCoordinator?.managedObjectModel else { throw CopyError.noCoordinator }
        var out: [String: Int] = [:]
        for entity in model.entities where !entity.isAbstract {
            guard let name = entity.name else { continue }
            out[name] = try context.count(for: request(entity))
        }
        return out
    }

    enum CopyError: Error { case noCoordinator }

    // MARK: Outils

    private static func request(_ entity: NSEntityDescription) -> NSFetchRequest<NSManagedObject> {
        let request = NSFetchRequest<NSManagedObject>()
        request.entity = entity
        // Une entité parente ne compte pas ses sous-entités (elles ont leur passe).
        request.includesSubentities = false
        return request
    }

    private static func fetchAll(_ entity: NSEntityDescription, in context: NSManagedObjectContext) throws -> [NSManagedObject] {
        let fetch = request(entity)
        fetch.returnsObjectsAsFaults = false
        return try context.fetch(fetch)
    }

    private static func ids(_ entity: NSEntityDescription, in context: NSManagedObjectContext) throws -> [UUID] {
        let fetch = NSFetchRequest<NSDictionary>()
        fetch.entity = entity
        fetch.includesSubentities = false
        fetch.resultType = .dictionaryResultType
        fetch.propertiesToFetch = [idKey]
        return try context.fetch(fetch).compactMap { $0[idKey] as? UUID }
    }

    private static func members(_ value: Any?) -> [NSManagedObject] {
        if let ordered = value as? NSOrderedSet { return ordered.array.compactMap { $0 as? NSManagedObject } }
        if let set = value as? NSSet { return set.allObjects.compactMap { $0 as? NSManagedObject } }
        return []
    }

    /// Un objet de la destination à partir d'un groupe d'originaux de même `id` :
    /// chaque attribut prend la première valeur non vide ; deux valeurs non vides
    /// différentes sont rapportées comme conflit (la première est gardée).
    private static func insertCopy(of originals: [NSManagedObject], entity: NSEntityDescription,
                                   into context: NSManagedObjectContext, id: UUID?,
                                   conflicts: inout [Conflict]) -> NSManagedObject {
        let copy = NSManagedObject(entity: entity, insertInto: context)
        for (name, attribute) in entity.attributesByName {
            guard !attribute.isTransient, !(attribute is NSDerivedAttributeDescription) else { continue }
            let values = originals.filter { $0.entity.attributesByName[name] != nil }
                .compactMap { $0.value(forKey: name) as? NSObject }
            guard let first = values.first else { continue }
            if let id, let entityName = entity.name, values.dropFirst().contains(where: { !$0.isEqual(first) }) {
                conflicts.append(Conflict(entity: entityName, id: id, key: name))
            }
            copy.setValue(first, forKey: name)
        }
        return copy
    }
}
