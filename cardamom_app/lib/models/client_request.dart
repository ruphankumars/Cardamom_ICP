class ClientRequest {
  final String requestId;
  final String requestType;
  final String status;
  final String clientUsername;
  final String clientName;
  final List<RequestItem> requestedItems;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? initialText;

  ClientRequest({
    required this.requestId,
    required this.requestType,
    required this.status,
    required this.clientUsername,
    required this.clientName,
    required this.requestedItems,
    required this.createdAt,
    required this.updatedAt,
    this.initialText,
  });

  factory ClientRequest.fromJson(Map<String, dynamic> json) {
    return ClientRequest(
      requestId: json['requestId']?.toString() ?? '',
      requestType: json['requestType']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      clientUsername: json['clientUsername']?.toString() ?? json['username']?.toString() ?? '',
      clientName: json['clientName']?.toString() ?? json['client']?.toString() ?? '',
      requestedItems: (json['requestedItems'] as List<dynamic>?)
              ?.map((item) => RequestItem.fromJson(item is Map<String, dynamic> ? item : <String, dynamic>{}))
              .toList() ??
          [],
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? '') ?? DateTime.now(),
      initialText: json['initialText']?.toString(),
    );
  }
}

class RequestItem {
  final String grade;
  final num? kgs;
  final num? no;
  final String? bagbox;
  final num? price;
  final String? brand;
  final String? notes;
  final num? offeredKgs;
  final num? offeredNo;
  final num? unitPrice;

  RequestItem({
    required this.grade,
    this.kgs,
    this.no,
    this.bagbox,
    this.price,
    this.brand,
    this.notes,
    this.offeredKgs,
    this.offeredNo,
    this.unitPrice,
  });

  factory RequestItem.fromJson(Map<String, dynamic> json) {
    return RequestItem(
      grade: json['grade']?.toString() ?? '',
      kgs: json['kgs'] != null ? num.tryParse(json['kgs'].toString()) : null,
      no: json['no'] != null ? num.tryParse(json['no'].toString()) : null,
      bagbox: json['bagbox']?.toString(),
      price: json['price'] != null ? num.tryParse(json['price'].toString()) : null,
      brand: json['brand']?.toString(),
      notes: json['notes']?.toString(),
      offeredKgs: json['offeredKgs'] != null ? num.tryParse(json['offeredKgs'].toString()) : null,
      offeredNo: json['offeredNo'] != null ? num.tryParse(json['offeredNo'].toString()) : null,
      unitPrice: json['unitPrice'] != null ? num.tryParse(json['unitPrice'].toString()) : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'grade': grade,
      'kgs': kgs,
      'no': no,
      'bagbox': bagbox,
      'price': price,
      'brand': brand,
      'notes': notes,
      'offeredKgs': offeredKgs,
      'offeredNo': offeredNo,
      'unitPrice': unitPrice,
    };
  }
}

class ChatMessage {
  final String messageId;
  final String senderRole;
  final String senderUsername;
  final String messageType;
  final String? message;
  final Map<String, dynamic>? payload;
  final DateTime timestamp;

  ChatMessage({
    required this.messageId,
    required this.senderRole,
    required this.senderUsername,
    required this.messageType,
    this.message,
    this.payload,
    required this.timestamp,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      messageId: json['messageId']?.toString() ?? '',
      senderRole: json['senderRole']?.toString() ?? '',
      senderUsername: json['senderUsername']?.toString() ?? '',
      messageType: json['messageType']?.toString() ?? '',
      message: json['message']?.toString(),
      payload: json['payload'] is Map<String, dynamic> ? json['payload'] : null,
      timestamp: DateTime.tryParse(json['timestamp']?.toString() ?? '') ?? DateTime.now(),
    );
  }
}
