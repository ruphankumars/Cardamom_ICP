/// Worker model for factory attendance system
class Worker {
  final String id;
  final String name;
  final String? phone;
  final double baseDailyWage;
  final double otHourlyRate;
  final String team;
  final bool isActive;
  final DateTime? createdAt;
  final double? similarity; // Optional, used for fuzzy search results
  final Map<String, dynamic>? faceData;
  final String? faceEnrolledAt;

  bool get hasFaceEnrolled => faceData != null && faceData!.isNotEmpty;

  Worker({
    required this.id,
    required this.name,
    this.phone,
    this.baseDailyWage = 500.0,
    this.otHourlyRate = 100.0,
    this.team = 'General',
    this.isActive = true,
    this.createdAt,
    this.similarity,
    this.faceData,
    this.faceEnrolledAt,
  });

  factory Worker.fromJson(Map<String, dynamic> json) {
    return Worker(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      phone: json['phone'] != null ? json['phone'].toString() : null,
      baseDailyWage: (json['baseDailyWage'] ?? 500).toDouble(),
      otHourlyRate: (json['otHourlyRate'] ?? 100).toDouble(),
      team: (json['team'] ?? 'General').toString(),
      isActive: json['isActive'] ?? true,
      createdAt: json['createdAt'] != null 
        ? DateTime.tryParse(json['createdAt']) 
        : null,
      similarity: json['similarity']?.toDouble(),
      faceData: json['faceData'] is Map ? Map<String, dynamic>.from(json['faceData']) : null,
      faceEnrolledAt: json['faceEnrolledAt']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'phone': phone,
      'baseDailyWage': baseDailyWage,
      'otHourlyRate': otHourlyRate,
      'team': team,
      'isActive': isActive,
      'createdAt': createdAt?.toIso8601String(),
      if (faceData != null) 'faceData': faceData,
      if (faceEnrolledAt != null) 'faceEnrolledAt': faceEnrolledAt,
    };
  }

  Worker copyWith({
    String? id,
    String? name,
    String? phone,
    double? baseDailyWage,
    double? otHourlyRate,
    String? team,
    bool? isActive,
    DateTime? createdAt,
    double? similarity,
    Map<String, dynamic>? faceData,
    String? faceEnrolledAt,
  }) {
    return Worker(
      id: id ?? this.id,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      baseDailyWage: baseDailyWage ?? this.baseDailyWage,
      otHourlyRate: otHourlyRate ?? this.otHourlyRate,
      team: team ?? this.team,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt ?? this.createdAt,
      similarity: similarity ?? this.similarity,
      faceData: faceData ?? this.faceData,
      faceEnrolledAt: faceEnrolledAt ?? this.faceEnrolledAt,
    );
  }
}

/// Attendance status enum
enum AttendanceStatus {
  full,
  halfAm,
  halfPm,
  ot;

  String get displayName {
    switch (this) {
      case AttendanceStatus.full:
        return 'Full Day';
      case AttendanceStatus.halfAm:
        return 'Half Day (AM)';
      case AttendanceStatus.halfPm:
        return 'Half Day (PM)';
      case AttendanceStatus.ot:
        return 'Overtime';
    }
  }

  String get apiValue {
    switch (this) {
      case AttendanceStatus.full:
        return 'full';
      case AttendanceStatus.halfAm:
        return 'half_am';
      case AttendanceStatus.halfPm:
        return 'half_pm';
      case AttendanceStatus.ot:
        return 'ot';
    }
  }

  static AttendanceStatus fromString(String? value) {
    switch (value) {
      case 'half_am':
      case 'half_day':  // backward compat with old records
        return AttendanceStatus.halfAm;
      case 'half_pm':
        return AttendanceStatus.halfPm;
      case 'ot':
      case 'overtime':  // backward compat
        return AttendanceStatus.ot;
      case 'full':
      case 'full_day':  // backward compat with old records
      case 'present':   // backward compat
      default:
        return AttendanceStatus.full;
    }
  }
}

/// Attendance record model
class AttendanceRecord {
  final String id;
  final String date;
  final String workerId;
  final String workerName;
  final AttendanceStatus status;
  final double otHours;
  final String? otReason;
  final double calculatedWage;
  final double? wageOverride;
  final double finalWage;
  final String? markedBy;
  final DateTime? markedAt;
  final DateTime? checkInTime;
  final DateTime? checkOutTime;

  AttendanceRecord({
    required this.id,
    required this.date,
    required this.workerId,
    required this.workerName,
    this.status = AttendanceStatus.full,
    this.otHours = 0,
    this.otReason,
    required this.calculatedWage,
    this.wageOverride,
    required this.finalWage,
    this.markedBy,
    this.markedAt,
    this.checkInTime,
    this.checkOutTime,
  });

  factory AttendanceRecord.fromJson(Map<String, dynamic> json) {
    return AttendanceRecord(
      id: json['id']?.toString() ?? '',
      date: json['date']?.toString() ?? '',
      workerId: json['workerId']?.toString() ?? '',
      workerName: json['workerName']?.toString() ?? '',
      status: AttendanceStatus.fromString(json['status']?.toString()),
      otHours: (json['otHours'] ?? 0).toDouble(),
      otReason: json['otReason']?.toString(),
      calculatedWage: (json['calculatedWage'] ?? 0).toDouble(),
      wageOverride: json['wageOverride'] != null ? (json['wageOverride']).toDouble() : null,
      finalWage: (json['finalWage'] ?? 0).toDouble(),
      markedBy: json['markedBy']?.toString(),
      markedAt: json['markedAt'] != null 
        ? DateTime.tryParse(json['markedAt'].toString()) 
        : null,
      checkInTime: json['checkInTime'] != null
        ? DateTime.tryParse(json['checkInTime'].toString())
        : null,
      checkOutTime: json['checkOutTime'] != null
        ? DateTime.tryParse(json['checkOutTime'].toString())
        : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'date': date,
      'workerId': workerId,
      'status': status.apiValue,
      'otHours': otHours,
      'otReason': otReason,
      'wageOverride': wageOverride,
      'markedBy': markedBy,
      if (checkInTime != null) 'checkInTime': checkInTime!.toIso8601String(),
      if (checkOutTime != null) 'checkOutTime': checkOutTime!.toIso8601String(),
    };
  }
}

/// Attendance summary for a date
class AttendanceSummary {
  final String date;
  final int totalWorkers;
  final int fullDay;
  final int halfAm;
  final int halfPm;
  final int overtime;
  final double totalWages;
  final List<AttendanceRecord> workers;

  AttendanceSummary({
    required this.date,
    required this.totalWorkers,
    this.fullDay = 0,
    this.halfAm = 0,
    this.halfPm = 0,
    this.overtime = 0,
    required this.totalWages,
    this.workers = const [],
  });

  factory AttendanceSummary.fromJson(Map<String, dynamic> json) {
    final breakdown = json['breakdown'] ?? {};
    final workersList = (json['workers'] as List<dynamic>?)
        ?.map((w) => AttendanceRecord.fromJson(w))
        .toList() ?? [];

    return AttendanceSummary(
      date: json['date'] ?? '',
      totalWorkers: json['totalWorkers'] ?? 0,
      fullDay: breakdown['full'] ?? 0,
      halfAm: breakdown['half_am'] ?? 0,
      halfPm: breakdown['half_pm'] ?? 0,
      overtime: breakdown['ot'] ?? 0,
      totalWages: (json['totalWages'] ?? 0).toDouble(),
      workers: workersList,
    );
  }
}

/// Calendar entry for month view
class CalendarEntry {
  final String date;
  final int workerCount;
  final double totalWages;

  CalendarEntry({
    required this.date,
    required this.workerCount,
    required this.totalWages,
  });

  factory CalendarEntry.fromJson(String date, Map<String, dynamic> json) {
    return CalendarEntry(
      date: date,
      workerCount: json['workerCount'] ?? 0,
      totalWages: (json['totalWages'] ?? 0).toDouble(),
    );
  }
}

/// Worker team
class WorkerTeam {
  final String id;
  final String name;

  WorkerTeam({required this.id, required this.name});

  factory WorkerTeam.fromJson(Map<String, dynamic> json) {
    return WorkerTeam(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
    );
  }
}

/// Search result with exact and similar matches
class WorkerSearchResult {
  final List<Worker> exactMatches;
  final List<Worker> similarMatches;

  WorkerSearchResult({
    required this.exactMatches,
    required this.similarMatches,
  });

  bool get hasMatches => exactMatches.isNotEmpty || similarMatches.isNotEmpty;
  bool get isEmpty => exactMatches.isEmpty && similarMatches.isEmpty;

  factory WorkerSearchResult.fromJson(Map<String, dynamic> json) {
    return WorkerSearchResult(
      exactMatches: (json['exactMatches'] as List<dynamic>?)
          ?.map((w) => Worker.fromJson(w))
          .toList() ?? [],
      similarMatches: (json['similarMatches'] as List<dynamic>?)
          ?.map((w) => Worker.fromJson(w))
          .toList() ?? [],
    );
  }
}
