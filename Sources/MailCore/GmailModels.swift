import Foundation

struct GmailProfile: Decodable {
    let emailAddress: String
    let historyId: String
}

struct GmailLabel: Decodable, Equatable {
    let id: String
    let name: String
    let type: String?
}

struct GmailLabelList: Decodable {
    let labels: [GmailLabel]?
}

struct GmailMessageRef: Decodable, Equatable {
    let id: String
    let threadId: String?
    let labelIds: [String]?
}

struct GmailMessageList: Decodable {
    let messages: [GmailMessageRef]?
    let nextPageToken: String?
}

struct GmailHeader: Decodable, Equatable {
    let name: String
    let value: String
}

struct GmailBody: Decodable, Equatable {
    let attachmentId: String?
    let size: Int?
    let data: String?
}

struct GmailPart: Decodable, Equatable {
    let partId: String?
    let mimeType: String?
    let filename: String?
    let headers: [GmailHeader]?
    let body: GmailBody?
    let parts: [GmailPart]?

    func header(_ name: String) -> String? {
        headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

struct GmailMessage: Decodable, Equatable {
    let id: String
    let threadId: String
    let labelIds: [String]?
    let snippet: String?
    let historyId: String?
    let internalDate: String?
    let sizeEstimate: Int?
    let payload: GmailPart?
}

struct HistoryRecord: Decodable, Equatable {
    struct Change: Decodable, Equatable {
        let message: GmailMessageRef
        let labelIds: [String]?
    }

    let id: String
    let messagesAdded: [Change]?
    let messagesDeleted: [Change]?
    let labelsAdded: [Change]?
    let labelsRemoved: [Change]?
}

struct HistoryList: Decodable {
    let history: [HistoryRecord]?
    let nextPageToken: String?
    let historyId: String?
}
