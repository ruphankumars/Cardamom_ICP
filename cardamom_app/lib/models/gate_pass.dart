/// Gate Pass data model for digital entry/exit notes
/// Used for tracking materials moving in/out of the factory

enum GatePassType { entry, exit }

enum GatePassPackaging { bag, box, mixed }

enum GatePassPurpose { auction, transport, local, return_ }

enum GatePassStatus { pending, approved, rejected }

class GatePass {
  final String id;
  final String passNumber;
  final GatePassType type;
  final GatePassPackaging packaging;
  final int bagCount;
  final int boxCount;
  final double bagWeight;
  final double boxWeight;
  final double calculatedWeight;
  final double actualWeight;
  final double finalWeight;
  final GatePassPurpose purpose;
  final String? notes;
  final String? vehicleNumber;
  final String? driverName;
  final String? driverPhone;
  final GatePassStatus status;
  final String requestedBy;
  final DateTime requestedAt;
  final String? approvedBy;
  final DateTime? approvedAt;
  final String? signatureData;
  final String? rejectionReason;
  final DateTime? actualEntryTime;
  final DateTime? actualExitTime;
  final bool isCompleted;
  final String? completedBy;
  final DateTime updatedAt;

  GatePass({
    required this.id,
    required this.passNumber,
    required this.type,
    required this.packaging,
    required this.bagCount,
    required this.boxCount,
    this.bagWeight = 50,
    this.boxWeight = 20,
    required this.calculatedWeight,
    required this.actualWeight,
    required this.finalWeight,
    required this.purpose,
    this.notes,
    this.vehicleNumber,
    this.driverName,
    this.driverPhone,
    required this.status,
    required this.requestedBy,
    required this.requestedAt,
    this.approvedBy,
    this.approvedAt,
    this.signatureData,
    this.rejectionReason,
    this.actualEntryTime,
    this.actualExitTime,
    this.isCompleted = false,
    this.completedBy,
    required this.updatedAt,
  });

  factory GatePass.fromJson(Map<String, dynamic> json) {
    return GatePass(
      id: json['id'] ?? '',
      passNumber: json['passNumber'] ?? '',
      type: _parseType(json['type']),
      packaging: _parsePackaging(json['packaging']),
      bagCount: int.tryParse(json['bagCount']?.toString() ?? '0') ?? 0,
      boxCount: int.tryParse(json['boxCount']?.toString() ?? '0') ?? 0,
      bagWeight: double.tryParse(json['bagWeight']?.toString() ?? '50') ?? 50,
      boxWeight: double.tryParse(json['boxWeight']?.toString() ?? '20') ?? 20,
      calculatedWeight: double.tryParse(json['calculatedWeight']?.toString() ?? '0') ?? 0,
      actualWeight: double.tryParse(json['actualWeight']?.toString() ?? '0') ?? 0,
      finalWeight: double.tryParse(json['finalWeight']?.toString() ?? '0') ?? 0,
      purpose: _parsePurpose(json['purpose']),
      notes: json['notes'],
      vehicleNumber: json['vehicleNumber'],
      driverName: json['driverName'],
      driverPhone: json['driverPhone'],
      status: _parseStatus(json['status']),
      requestedBy: json['requestedBy'] ?? '',
      requestedAt: DateTime.tryParse(json['requestedAt'] ?? '') ?? DateTime.now(),
      approvedBy: json['approvedBy'],
      approvedAt: json['approvedAt'] != null && json['approvedAt'].toString().isNotEmpty
          ? DateTime.tryParse(json['approvedAt'].toString())
          : null,
      signatureData: json['signatureData'],
      rejectionReason: json['rejectionReason'],
      actualEntryTime: json['actualEntryTime'] != null && json['actualEntryTime'].toString().isNotEmpty
          ? DateTime.tryParse(json['actualEntryTime'].toString())
          : null,
      actualExitTime: json['actualExitTime'] != null && json['actualExitTime'].toString().isNotEmpty
          ? DateTime.tryParse(json['actualExitTime'].toString())
          : null,
      isCompleted: json['isCompleted'] == true || json['isCompleted'] == 'true',
      completedBy: json['completedBy'],
      updatedAt: DateTime.tryParse(json['updatedAt'] ?? '') ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'passNumber': passNumber,
    'type': type.name,
    'packaging': packaging.name,
    'bagCount': bagCount,
    'boxCount': boxCount,
    'bagWeight': bagWeight,
    'boxWeight': boxWeight,
    'calculatedWeight': calculatedWeight,
    'actualWeight': actualWeight,
    'finalWeight': finalWeight,
    'purpose': purpose == GatePassPurpose.return_ ? 'return' : purpose.name,
    'notes': notes,
    'vehicleNumber': vehicleNumber,
    'driverName': driverName,
    'driverPhone': driverPhone,
    'status': status.name,
    'requestedBy': requestedBy,
    'requestedAt': requestedAt.toIso8601String(),
    'approvedBy': approvedBy,
    'approvedAt': approvedAt?.toIso8601String(),
    'signatureData': signatureData,
    'rejectionReason': rejectionReason,
    'actualEntryTime': actualEntryTime?.toIso8601String(),
    'actualExitTime': actualExitTime?.toIso8601String(),
    'isCompleted': isCompleted,
    'completedBy': completedBy,
    'updatedAt': updatedAt.toIso8601String(),
  };

  static GatePassType _parseType(String? type) {
    switch (type?.toLowerCase()) {
      case 'entry': return GatePassType.entry;
      case 'exit': return GatePassType.exit;
      default: return GatePassType.exit;
    }
  }

  static GatePassPackaging _parsePackaging(String? packaging) {
    switch (packaging?.toLowerCase()) {
      case 'bag': return GatePassPackaging.bag;
      case 'box': return GatePassPackaging.box;
      case 'mixed': return GatePassPackaging.mixed;
      default: return GatePassPackaging.bag;
    }
  }

  static GatePassPurpose _parsePurpose(String? purpose) {
    switch (purpose?.toLowerCase()) {
      case 'auction': return GatePassPurpose.auction;
      case 'transport': return GatePassPurpose.transport;
      case 'local': return GatePassPurpose.local;
      case 'return': return GatePassPurpose.return_;
      default: return GatePassPurpose.transport;
    }
  }

  static GatePassStatus _parseStatus(String? status) {
    switch (status?.toLowerCase()) {
      case 'pending': return GatePassStatus.pending;
      case 'approved': return GatePassStatus.approved;
      case 'rejected': return GatePassStatus.rejected;
      default: return GatePassStatus.pending;
    }
  }

  /// Check if this pass is pending approval
  bool get isPending => status == GatePassStatus.pending;
  
  /// Check if this pass has been approved
  bool get isApproved => status == GatePassStatus.approved;
  
  /// Check if this pass was rejected
  bool get isRejected => status == GatePassStatus.rejected;

  /// Get display string for type
  String get typeDisplay => type == GatePassType.entry ? 'Entry' : 'Exit';

  /// Get display string for packaging
  String get packagingDisplay {
    switch (packaging) {
      case GatePassPackaging.bag: return 'Bags';
      case GatePassPackaging.box: return 'Boxes';
      case GatePassPackaging.mixed: return 'Mixed';
    }
  }

  /// Get display string for purpose
  String get purposeDisplay {
    switch (purpose) {
      case GatePassPurpose.auction: return 'Auction';
      case GatePassPurpose.transport: return 'Transport';
      case GatePassPurpose.local: return 'Local';
      case GatePassPurpose.return_: return 'Return';
    }
  }

  /// Get display string for status with emoji
  String get statusDisplay {
    switch (status) {
      case GatePassStatus.pending: return '⏳ Pending';
      case GatePassStatus.approved: return '✅ Approved';
      case GatePassStatus.rejected: return '❌ Rejected';
    }
  }

  /// Get weight summary string
  String get weightSummary {
    final parts = <String>[];
    if (bagCount > 0) parts.add('$bagCount bags × ${bagWeight.toInt()}kg');
    if (boxCount > 0) parts.add('$boxCount boxes × ${boxWeight.toInt()}kg');
    return parts.isEmpty ? 'No items' : '${parts.join(' + ')} = ${finalWeight.toInt()}kg';
  }

  /// Tracking helpers
  bool get canRecordEntry => isApproved && actualEntryTime == null && !isCompleted;
  bool get canRecordExit => isApproved && actualEntryTime != null && actualExitTime == null && !isCompleted;
  bool get canComplete => isApproved && actualExitTime != null && !isCompleted;
  
  String? get entryTimeFormatted => actualEntryTime != null ? _formatDateTime(actualEntryTime!) : null;
  String? get exitTimeFormatted => actualExitTime != null ? _formatDateTime(actualExitTime!) : null;

  String _formatDateTime(DateTime dt) {
    return '${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
