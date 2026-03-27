import 'package:flutter/material.dart';

enum TaskStatus {
  pending,
  ongoing,
  completed,
  overdue
}

enum RepeatType {
  none,
  daily,
  weekly,
  monthly,
  yearly
}

enum EarlyReminder {
  none,
  fiveMinutes,
  fifteenMinutes,
  thirtyMinutes,
  oneHour,
  oneDay,
  twoDays,
  sameDay
}

class Subtask {
  final String title;
  final bool completed;

  Subtask({required this.title, this.completed = false});

  factory Subtask.fromJson(Map<String, dynamic> json) {
    return Subtask(
      title: json['title']?.toString() ?? '',
      completed: json['completed'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'title': title,
    'completed': completed,
  };

  Subtask copyWith({String? title, bool? completed}) {
    return Subtask(
      title: title ?? this.title,
      completed: completed ?? this.completed,
    );
  }
}

class Task {
  final String id;
  final String title;
  final String description;
  final String notes;
  final String url;
  final String assigneeId;
  final String assigneeName;
  final DateTime? deadline;
  final DateTime? dueDate;
  final TimeOfDay? dueTime;
  final bool hasDueDate;
  final bool hasDueTime;
  final bool isUrgent;
  final RepeatType repeatType;
  final String endRepeat; // 'never', 'date', 'count'
  final DateTime? endRepeatDate;
  final int? endRepeatCount;
  final EarlyReminder earlyReminder;
  final String listName;
  final List<String> tags;
  final List<Subtask> subtasks;
  final bool isFlagged;
  final String priority; // 'none', 'low', 'medium', 'high'
  final TaskStatus status;
  final bool hasLocation;
  final Map<String, dynamic>? locationData;
  final bool whenMessaging;
  final String? imageUrl;
  final List<String> dependsOn; // List of task IDs this task depends on
  final DateTime createdAt;
  final DateTime? updatedAt;

  Task({
    required this.id,
    required this.title,
    this.description = '',
    this.notes = '',
    this.url = '',
    this.assigneeId = '',
    this.assigneeName = '',
    this.deadline,
    this.dueDate,
    this.dueTime,
    this.hasDueDate = false,
    this.hasDueTime = false,
    this.isUrgent = false,
    this.repeatType = RepeatType.none,
    this.endRepeat = 'never',
    this.endRepeatDate,
    this.endRepeatCount,
    this.earlyReminder = EarlyReminder.none,
    this.listName = 'Tasks',
    this.tags = const [],
    this.subtasks = const [],
    this.isFlagged = false,
    this.priority = 'none',
    this.status = TaskStatus.pending,
    this.hasLocation = false,
    this.locationData,
    this.whenMessaging = false,
    this.imageUrl,
    this.dependsOn = const [],
    required this.createdAt,
    this.updatedAt,
  });

  factory Task.fromJson(Map<String, dynamic> json) {
    return Task(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      notes: json['notes']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
      assigneeId: json['assigneeId']?.toString() ?? '',
      assigneeName: json['assigneeName']?.toString() ?? '',
      deadline: _parseDateTime(json['deadline']),
      dueDate: _parseDateTime(json['dueDate']),
      dueTime: _parseTimeOfDay(json['dueTime']),
      hasDueDate: json['hasDueDate'] == true,
      hasDueTime: json['hasDueTime'] == true,
      isUrgent: json['isUrgent'] == true,
      repeatType: _parseRepeatType(json['repeatType']),
      endRepeat: json['endRepeat']?.toString() ?? 'never',
      endRepeatDate: _parseDateTime(json['endRepeatDate']),
      endRepeatCount: json['endRepeatCount'] is int ? json['endRepeatCount'] : null,
      earlyReminder: _parseEarlyReminder(json['earlyReminder']),
      listName: json['listName']?.toString() ?? 'Tasks',
      tags: (json['tags'] as List<dynamic>?)?.map((t) => t.toString()).toList() ?? [],
      subtasks: (json['subtasks'] as List<dynamic>?)
          ?.map((s) => Subtask.fromJson(s as Map<String, dynamic>))
          .toList() ?? [],
      isFlagged: json['isFlagged'] == true,
      priority: json['priority']?.toString() ?? 'none',
      status: _parseStatus(json['status']?.toString()),
      hasLocation: json['hasLocation'] == true,
      locationData: json['locationData'] as Map<String, dynamic>?,
      whenMessaging: json['whenMessaging'] == true,
      imageUrl: json['imageUrl']?.toString(),
      dependsOn: (json['dependsOn'] as List<dynamic>?)?.map((d) => d.toString()).toList() ?? [],
      createdAt: _parseDateTime(json['createdAt']) ?? DateTime.now(),
      updatedAt: _parseDateTime(json['updatedAt']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'description': description,
      'notes': notes,
      'url': url,
      'assigneeId': assigneeId,
      'assigneeName': assigneeName,
      'deadline': deadline?.toIso8601String(),
      'dueDate': dueDate?.toIso8601String(),
      'dueTime': dueTime != null ? '${dueTime!.hour.toString().padLeft(2, '0')}:${dueTime!.minute.toString().padLeft(2, '0')}' : null,
      'hasDueDate': hasDueDate,
      'hasDueTime': hasDueTime,
      'isUrgent': isUrgent,
      'repeatType': repeatType.name,
      'endRepeat': endRepeat,
      'endRepeatDate': endRepeatDate?.toIso8601String(),
      'endRepeatCount': endRepeatCount,
      'earlyReminder': _earlyReminderToString(earlyReminder),
      'listName': listName,
      'tags': tags,
      'subtasks': subtasks.map((s) => s.toJson()).toList(),
      'isFlagged': isFlagged,
      'priority': priority,
      'status': status == TaskStatus.ongoing ? 'in_progress' : status.name,
      'hasLocation': hasLocation,
      'locationData': locationData,
      'whenMessaging': whenMessaging,
      'imageUrl': imageUrl,
      'dependsOn': dependsOn,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt?.toIso8601String(),
    };
  }

  static DateTime? _parseDateTime(dynamic value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString());
  }

  static TimeOfDay? _parseTimeOfDay(dynamic value) {
    if (value == null) return null;
    final str = value.toString();
    final parts = str.split(':');
    if (parts.length >= 2) {
      final hour = int.tryParse(parts[0]);
      final minute = int.tryParse(parts[1]);
      if (hour != null && minute != null) {
        return TimeOfDay(hour: hour, minute: minute);
      }
    }
    return null;
  }

  static TaskStatus _parseStatus(String? status) {
    switch (status?.toLowerCase()) {
      case 'ongoing':
      case 'in_progress':
        return TaskStatus.ongoing;
      case 'completed':
        return TaskStatus.completed;
      case 'overdue':
        return TaskStatus.overdue;
      case 'pending':
      default:
        return TaskStatus.pending;
    }
  }

  static RepeatType _parseRepeatType(dynamic value) {
    switch (value?.toString().toLowerCase()) {
      case 'daily':
        return RepeatType.daily;
      case 'weekly':
        return RepeatType.weekly;
      case 'monthly':
        return RepeatType.monthly;
      case 'yearly':
        return RepeatType.yearly;
      default:
        return RepeatType.none;
    }
  }

  static EarlyReminder _parseEarlyReminder(dynamic value) {
    switch (value?.toString().toLowerCase()) {
      case '5min':
      case 'fiveminutes':
        return EarlyReminder.fiveMinutes;
      case '15min':
      case 'fifteenminutes':
        return EarlyReminder.fifteenMinutes;
      case '30min':
      case 'thirtyminutes':
        return EarlyReminder.thirtyMinutes;
      case '1hour':
      case 'onehour':
        return EarlyReminder.oneHour;
      case '1day':
      case 'oneday':
        return EarlyReminder.oneDay;
      case '2days':
      case 'twodays':
        return EarlyReminder.twoDays;
      case 'sameday':
        return EarlyReminder.sameDay;
      default:
        return EarlyReminder.none;
    }
  }

  static String _earlyReminderToString(EarlyReminder reminder) {
    switch (reminder) {
      case EarlyReminder.fiveMinutes:
        return '5min';
      case EarlyReminder.fifteenMinutes:
        return '15min';
      case EarlyReminder.thirtyMinutes:
        return '30min';
      case EarlyReminder.oneHour:
        return '1hour';
      case EarlyReminder.oneDay:
        return '1day';
      case EarlyReminder.twoDays:
        return '2days';
      case EarlyReminder.sameDay:
        return 'sameday';
      default:
        return 'none';
    }
  }

  Task copyWith({
    String? title,
    String? description,
    String? notes,
    String? url,
    String? assigneeId,
    String? assigneeName,
    DateTime? deadline,
    DateTime? dueDate,
    TimeOfDay? dueTime,
    bool? hasDueDate,
    bool? hasDueTime,
    bool? isUrgent,
    RepeatType? repeatType,
    String? endRepeat,
    DateTime? endRepeatDate,
    int? endRepeatCount,
    EarlyReminder? earlyReminder,
    String? listName,
    List<String>? tags,
    List<Subtask>? subtasks,
    bool? isFlagged,
    String? priority,
    TaskStatus? status,
    bool? hasLocation,
    Map<String, dynamic>? locationData,
    bool? whenMessaging,
    String? imageUrl,
    List<String>? dependsOn,
  }) {
    return Task(
      id: id,
      title: title ?? this.title,
      description: description ?? this.description,
      notes: notes ?? this.notes,
      url: url ?? this.url,
      assigneeId: assigneeId ?? this.assigneeId,
      assigneeName: assigneeName ?? this.assigneeName,
      deadline: deadline ?? this.deadline,
      dueDate: dueDate ?? this.dueDate,
      dueTime: dueTime ?? this.dueTime,
      hasDueDate: hasDueDate ?? this.hasDueDate,
      hasDueTime: hasDueTime ?? this.hasDueTime,
      isUrgent: isUrgent ?? this.isUrgent,
      repeatType: repeatType ?? this.repeatType,
      endRepeat: endRepeat ?? this.endRepeat,
      endRepeatDate: endRepeatDate ?? this.endRepeatDate,
      endRepeatCount: endRepeatCount ?? this.endRepeatCount,
      earlyReminder: earlyReminder ?? this.earlyReminder,
      listName: listName ?? this.listName,
      tags: tags ?? this.tags,
      subtasks: subtasks ?? this.subtasks,
      isFlagged: isFlagged ?? this.isFlagged,
      priority: priority ?? this.priority,
      status: status ?? this.status,
      hasLocation: hasLocation ?? this.hasLocation,
      locationData: locationData ?? this.locationData,
      whenMessaging: whenMessaging ?? this.whenMessaging,
      imageUrl: imageUrl ?? this.imageUrl,
      dependsOn: dependsOn ?? this.dependsOn,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }
}
