import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:html' as html;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CogniPlan',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const DailyPlanner(),
    );
  }
}

class DailyPlanner extends StatefulWidget {
  const DailyPlanner({super.key});

  @override
  State<DailyPlanner> createState() => _DailyPlannerState();
}

class _DailyPlannerState extends State<DailyPlanner> {
  final Map<String, Map<int, Map<String, dynamic>>> _allPlans = {};
  DateTime _selectedDate = DateTime.now();
  int? _editingHour;
  Color _selectedColor = Colors.blue;
  Timer? _notificationTimer;
  int _lastNotifiedHour = -1;
  bool _isWeeklyView = false;
  bool _isDarkMode = false;

  @override
  void initState() {
    super.initState();
    _loadPlans();
    _startNotificationCheck();
  }

  @override
  void dispose() {
    _notificationTimer?.cancel();
    super.dispose();
  }

  void _requestNotificationPermission() {
    html.Notification.requestPermission().then((permission) {
      if (permission == 'granted') {
        _showNotification('Bildirim Aktif', 'Plan saatlerinde size bildirim göndereceğiz!');
        setState(() {});
      }
    });
  }

  void _showNotification(String title, String body) {
    if (html.Notification.permission == 'granted') {
      html.Notification(title, body: body, icon: '/icons/Icon-192.png');
    }
  }

  void _startNotificationCheck() {
    _notificationTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
      _checkAndSendNotifications();
    });
  }

  void _checkAndSendNotifications() {
    final now = DateTime.now();
    final currentHour = now.hour;
    final today = DateTime(now.year, now.month, now.day);
    final dateKey = _dateKey(today);
    final dayPlans = _allPlans[dateKey] ?? {};

    if (currentHour != _lastNotifiedHour) {
      final planData = dayPlans[currentHour];
      if (planData != null && planData['text'] != null && planData['text'] != 'Uyku') {
        _showNotification(
          'Plan Saati!',
          '${currentHour.toString().padLeft(2, '0')}:00 - ${planData['text']}',
        );
        _lastNotifiedHour = currentHour;
      }
    }
  }

  Future<void> _loadPlans() async {
    final prefs = await SharedPreferences.getInstance();
    final plansJson = prefs.getString('plans');
    if (plansJson != null) {
      try {
        final Map<String, dynamic> decoded = jsonDecode(plansJson);
        decoded.forEach((dateKey, hours) {
          _allPlans[dateKey] = {};
          (hours as Map<String, dynamic>).forEach((hourStr, planData) {
            final colorValue = planData['color'];
            final Color color = colorValue is Color 
                ? colorValue 
                : (colorValue is int ? Color(colorValue) : const Color(0xFF3B82F6));
            _allPlans[dateKey]![int.parse(hourStr)] = {
              'text': planData['text'],
              'color': color,
              'completed': planData['completed'] ?? false,
              'priority': planData['priority'] ?? 'medium',
              'repeat': planData['repeat'] ?? 'none',
              'reminders': planData['reminders'] ?? [],
            };
          });
        });
        _applyRepeatingPlans();
        setState(() {});
      } catch (e) {
        // Clear corrupted data and start fresh
        await prefs.remove('plans');
        _allPlans.clear();
        setState(() {});
      }
    }
  }

  void _applyRepeatingPlans() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    final nextWeek = today.add(const Duration(days: 7));

    // Collect all changes first to avoid concurrent modification
    final List<Map<String, dynamic>> pendingChanges = [];

    final dateKeys = _allPlans.keys.toList();
    for (final dateKey in dateKeys) {
      final hours = _allPlans[dateKey];
      if (hours == null) continue;

      final dateParts = dateKey.split('-');
      final planDate = DateTime(
        int.parse(dateParts[0]),
        int.parse(dateParts[1]),
        int.parse(dateParts[2]),
      );

      hours.forEach((hour, planData) {
        final repeat = planData['repeat'] ?? 'none';
        if (repeat == 'none') return;

        // Ensure color is a Color object
        final colorValue = planData['color'];
        final Color color = colorValue is Color 
            ? colorValue 
            : (colorValue is int ? Color(colorValue) : const Color(0xFF3B82F6));

        if (repeat == 'daily') {
          final targetDate = planDate.add(const Duration(days: 1));
          if (targetDate.isAtSameMomentAs(tomorrow) || targetDate.isAfter(tomorrow)) {
            final targetKey = _dateKey(targetDate);
            pendingChanges.add({
              'type': 'add',
              'targetKey': targetKey,
              'hour': hour,
              'planData': {
                'text': planData['text'],
                'color': color,
                'completed': false,
                'priority': planData['priority'],
                'repeat': repeat,
              },
            });
          }
        } else if (repeat == 'weekly') {
          final targetDate = planDate.add(const Duration(days: 7));
          if (targetDate.isAtSameMomentAs(nextWeek) || targetDate.isAfter(nextWeek)) {
            final targetKey = _dateKey(targetDate);
            pendingChanges.add({
              'type': 'add',
              'targetKey': targetKey,
              'hour': hour,
              'planData': {
                'text': planData['text'],
                'color': color,
                'completed': false,
                'priority': planData['priority'],
                'repeat': repeat,
              },
            });
          }
        }
      });
    }

    // Apply all pending changes
    for (final change in pendingChanges) {
      if (change['type'] == 'add') {
        final targetKey = change['targetKey'] as String;
        final hour = change['hour'] as int;
        final planData = change['planData'] as Map<String, dynamic>;

        if (!_allPlans.containsKey(targetKey)) {
          _allPlans[targetKey] = {};
        }
        if (!_allPlans[targetKey]!.containsKey(hour)) {
          _allPlans[targetKey]![hour] = planData;
        }
      }
    }
  }

  Future<void> _savePlans() async {
    final prefs = await SharedPreferences.getInstance();
    final Map<String, dynamic> encoded = {};
    _allPlans.forEach((dateKey, hours) {
      encoded[dateKey] = {};
      hours.forEach((hour, planData) {
        encoded[dateKey]![hour.toString()] = {
          'text': planData['text'],
          'color': planData['color'].value,
          'completed': planData['completed'] ?? false,
          'priority': planData['priority'] ?? 'medium',
          'repeat': planData['repeat'] ?? 'none',
          'reminders': planData['reminders'] ?? [],
        };
      });
    });
    await prefs.setString('plans', jsonEncode(encoded));
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final selectedDay = DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day);
    final isToday = today.isAtSameMomentAs(selectedDay);
    final dayPlans = _allPlans[_dateKey(_selectedDate)] ?? {};
    final isMobile = MediaQuery.of(context).size.width < 600;

    // Build gradient colors from daily slot colors
    List<Color> gradientColors = [];
    for (int i = 0; i < 24; i++) {
      final planData = dayPlans[i];
      final colorValue = planData?['color'];
      final Color color = colorValue is Color 
          ? colorValue 
          : (colorValue is int ? Color(colorValue) : const Color(0xFFE2E8F0));
      gradientColors.add(color);
    }

    return Scaffold(
      backgroundColor: _isDarkMode ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: _isDarkMode ? const Color(0xFF1E293B) : Colors.white,
        elevation: 0,
        toolbarHeight: isMobile ? 75 : 90,
        flexibleSpace: Column(
          children: [
            // Color blocks at the top
            Container(
              height: isMobile ? 4 : 6,
              margin: EdgeInsets.fromLTRB(isMobile ? 12 : 16, isMobile ? 8 : 12, isMobile ? 12 : 16, 0),
              child: Row(
                children: List.generate(24, (index) {
                  final color = gradientColors[index];
                  return Expanded(
                    child: Container(
                      color: color,
                      margin: EdgeInsets.only(right: index < 23 ? 1 : 0),
                    ),
                  );
                }),
              ),
            ),
            // Header content
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 16, vertical: isMobile ? 6 : 8),
                child: Row(
                  children: [
                    // Navigation left
                    Container(
                      decoration: BoxDecoration(
                        color: _isDarkMode ? const Color(0xFF334155) : const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(isMobile ? 8 : 10),
                      ),
                      child: IconButton(
                        icon: Icon(Icons.chevron_left, color: _isDarkMode ? Colors.white : const Color(0xFF475569), size: isMobile ? 18 : 20),
                        onPressed: () {
                          setState(() {
                            _selectedDate = _selectedDate.subtract(const Duration(days: 1));
                            _editingHour = null;
                          });
                        },
                        constraints: BoxConstraints(minWidth: isMobile ? 36 : 40, minHeight: isMobile ? 36 : 40),
                      ),
                    ),
                    SizedBox(width: isMobile ? 10 : 14),
                    // Date and time
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  _formatDate(_selectedDate),
                                  style: TextStyle(
                                    fontSize: isMobile ? 14 : 17,
                                    fontWeight: FontWeight.w700,
                                    color: _isDarkMode ? Colors.white : const Color(0xFF1E293B),
                                    letterSpacing: -0.3,
                                  ),
                                ),
                              ),
                              if (isToday) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.all(3),
                                  decoration: BoxDecoration(
                                    color: Colors.blue.withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: Colors.blue.withOpacity(0.2),
                                      width: 1,
                                    ),
                                  ),
                                  child: Icon(
                                    Icons.today,
                                    size: isMobile ? 12 : 14,
                                    color: Colors.blue,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (!isMobile) ...[
                      // Clock - show time on desktop
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: _isDarkMode ? const Color(0xFF334155) : const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: StreamBuilder(
                          stream: Stream.periodic(const Duration(seconds: 1), (count) => count),
                          builder: (context, snapshot) {
                            final now = DateTime.now();
                            final time = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
                            return Text(
                              time,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: _isDarkMode ? Colors.white : const Color(0xFF475569),
                                letterSpacing: 1,
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                    ] else ...[
                      // Clock icon on mobile
                      Container(
                        decoration: BoxDecoration(
                          color: _isDarkMode ? const Color(0xFF334155) : const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: IconButton(
                          icon: Icon(Icons.access_time, color: _isDarkMode ? Colors.white : const Color(0xFF475569), size: 16),
                          onPressed: () {
                            final now = DateTime.now();
                            final time = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(time),
                                duration: const Duration(seconds: 2),
                                behavior: SnackBarBehavior.floating,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                            );
                          },
                          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                        ),
                      ),
                      const SizedBox(width: 4),
                    ],
                    // Notification
                    Container(
                      decoration: BoxDecoration(
                        color: _isDarkMode ? const Color(0xFF334155) : const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(isMobile ? 8 : 10),
                      ),
                      child: IconButton(
                        icon: Icon(
                          html.Notification.permission == 'granted' 
                              ? Icons.notifications_active 
                              : Icons.notifications_none,
                          color: _isDarkMode ? Colors.white : const Color(0xFF475569),
                          size: isMobile ? 16 : 18,
                        ),
                        onPressed: () {
                          _requestNotificationPermission();
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                html.Notification.permission == 'granted'
                                    ? 'Bildirimler aktif'
                                    : 'Bildirim izni gerekli',
                              ),
                              duration: const Duration(seconds: 2),
                              behavior: SnackBarBehavior.floating,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          );
                        },
                        constraints: BoxConstraints(minWidth: isMobile ? 32 : 36, minHeight: isMobile ? 32 : 36),
                      ),
                    ),
                    SizedBox(width: isMobile ? 4 : 6),
                    // View toggle
                    Container(
                      padding: EdgeInsets.all(isMobile ? 6 : 8),
                      decoration: BoxDecoration(
                        color: _isWeeklyView ? Colors.blue.withOpacity(0.1) : (_isDarkMode ? const Color(0xFF334155) : const Color(0xFFF1F5F9)),
                        borderRadius: BorderRadius.circular(isMobile ? 8 : 10),
                        border: Border.all(
                          color: _isWeeklyView ? Colors.blue.withOpacity(0.3) : Colors.transparent,
                          width: 1,
                        ),
                      ),
                      child: GestureDetector(
                        onTap: () {
                          setState(() {
                            _isWeeklyView = !_isWeeklyView;
                          });
                        },
                        child: Icon(
                          _isWeeklyView ? Icons.view_week : Icons.calendar_today,
                          color: _isWeeklyView ? Colors.blue : (_isDarkMode ? Colors.white : const Color(0xFF475569)),
                          size: isMobile ? 16 : 18,
                        ),
                      ),
                    ),
                    SizedBox(width: isMobile ? 4 : 6),
                    // More options menu
                    Container(
                      decoration: BoxDecoration(
                        color: _isDarkMode ? const Color(0xFF334155) : const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(isMobile ? 8 : 10),
                      ),
                      child: PopupMenuButton<String>(
                        icon: Icon(Icons.more_horiz, color: _isDarkMode ? Colors.white : const Color(0xFF475569), size: isMobile ? 18 : 20),
                        onSelected: (value) {
                          switch (value) {
                            case 'search':
                              _showSearchDialog();
                              break;
                            case 'statistics':
                              _showStatisticsDialog();
                              break;
                            case 'export':
                              _exportPlans();
                              break;
                            case 'darkmode':
                              setState(() {
                                _isDarkMode = !_isDarkMode;
                              });
                              break;
                          }
                        },
                        itemBuilder: (context) => [
                          const PopupMenuItem(
                            value: 'search',
                            child: Row(
                              children: [
                                Icon(Icons.search, size: 18),
                                SizedBox(width: 12),
                                Text('Plan Ara'),
                              ],
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'statistics',
                            child: Row(
                              children: [
                                Icon(Icons.bar_chart, size: 18),
                                SizedBox(width: 12),
                                Text('İstatistikler'),
                              ],
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'export',
                            child: Row(
                              children: [
                                Icon(Icons.download, size: 18),
                                SizedBox(width: 12),
                                Text('Dışa Aktar'),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'darkmode',
                            child: Row(
                              children: [
                                Icon(_isDarkMode ? Icons.dark_mode : Icons.light_mode, size: 18),
                                const SizedBox(width: 12),
                                Text(_isDarkMode ? 'Aydınlık Mod' : 'Karanlık Mod'),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: isMobile ? 4 : 8),
                    // Navigation right
                    Container(
                      decoration: BoxDecoration(
                        color: _isDarkMode ? const Color(0xFF334155) : const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(isMobile ? 8 : 10),
                      ),
                      child: IconButton(
                        icon: Icon(Icons.chevron_right, color: _isDarkMode ? Colors.white : const Color(0xFF475569), size: isMobile ? 18 : 20),
                        onPressed: () {
                          setState(() {
                            _selectedDate = _selectedDate.add(const Duration(days: 1));
                            _editingHour = null;
                          });
                        },
                        constraints: BoxConstraints(minWidth: isMobile ? 36 : 40, minHeight: isMobile ? 36 : 40),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () {
                if (_editingHour != null) {
                  setState(() {
                    _editingHour = null;
                  });
                }
              },
              child: _isWeeklyView ? _buildWeeklyView() : _buildDailyView(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDailyView() {
    final now = DateTime.now();
    final currentHour = now.hour;
    final today = DateTime(now.year, now.month, now.day);
    final selectedDay = DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day);
    final isToday = today.isAtSameMomentAs(selectedDay);
    final isPastDate = selectedDay.isBefore(today);
    final dayPlans = _allPlans[_dateKey(_selectedDate)] ?? {};

    return Expanded(
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        separatorBuilder: (context, index) => const SizedBox(height: 8),
        itemCount: 24,
        itemBuilder: (context, index) {
          final hour = index;
          final isSleepHour = hour >= 0 && hour <= 8;
          final isPastHour = isToday && hour < currentHour;
          final isPast = isPastDate || isPastHour;
          final isCurrent = isToday && hour == currentHour;
          final isEditing = _editingHour == hour;
          final planData = dayPlans[hour];
          final plan = planData?['text'] ?? '';
          final colorValue = planData?['color'];
          final planColor = colorValue is Color 
              ? colorValue 
              : (colorValue is int ? Color(colorValue) : const Color(0xFF3B82F6));

          if (isEditing) {
            return _buildEditingSlot(hour, Colors.white, dayPlans);
          }

          return _buildSlot(hour, Colors.white, plan, planColor, isPast, isCurrent, isPastDate, isSleepHour);
        },
      ),
    );
  }

  Widget _buildWeeklyView() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final startOfWeek = _selectedDate.subtract(Duration(days: _selectedDate.weekday - 1));
    
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: 7,
      itemBuilder: (context, index) {
        final date = startOfWeek.add(Duration(days: index));
        final dateKey = _dateKey(date);
        final dayPlans = _allPlans[dateKey] ?? {};
        final isToday = date.isAtSameMomentAs(today);
        final isPast = date.isBefore(today);
        
        return Container(
          margin: const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(
            color: _isDarkMode ? const Color(0xFF334155) : Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.04),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: isToday ? Colors.blue.withOpacity(0.1) : (_isDarkMode ? const Color(0xFF475569) : Colors.grey[50]),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(16),
                    topRight: Radius.circular(16),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _formatDate(date),
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: _isDarkMode ? Colors.white : const Color(0xFF1E293B),
                          ),
                        ),
                        if (isToday)
                          const Text(
                            'Bugün',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.blue,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ),
                    Text(
                      '${dayPlans.length} plan',
                      style: TextStyle(
                        fontSize: 14,
                        color: _isDarkMode ? Colors.grey[400] : const Color(0xFF64748B),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              if (dayPlans.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Center(
                    child: Text(
                      isPast ? 'Geçmiş' : 'Plan yok',
                      style: TextStyle(
                        color: isPast ? Colors.grey[400] : Colors.grey[600],
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                )
              else
                ...dayPlans.entries.map((entry) {
                  final hour = entry.key;
                  final planData = entry.value;
                  final plan = planData['text'] ?? '';
                  final colorValue = planData['color'];
                  final planColor = colorValue is Color 
                      ? colorValue 
                      : (colorValue is int ? Color(colorValue) : const Color(0xFF3B82F6));
                  final isCompleted = planData['completed'] ?? false;
                  
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    leading: Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        color: planColor.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        '${hour.toString().padLeft(2, '0')}:00',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          color: planColor,
                        ),
                      ),
                    ),
                    title: Row(
                      children: [
                        GestureDetector(
                          onTap: () {
                            setState(() {
                              final plans = _allPlans[dateKey];
                              if (plans != null && plans[hour] != null) {
                                plans[hour]!['completed'] = !isCompleted;
                                _savePlans();
                              }
                            });
                          },
                          child: Container(
                            width: 20,
                            height: 20,
                            margin: const EdgeInsets.only(right: 8),
                            decoration: BoxDecoration(
                              color: isCompleted ? planColor : Colors.transparent,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: planColor,
                                width: 2,
                              ),
                            ),
                            child: isCompleted
                                ? const Icon(Icons.check, color: Colors.white, size: 14)
                                : null,
                          ),
                        ),
                        Expanded(
                          child: Text(
                            plan,
                            style: TextStyle(
                              color: isCompleted ? Colors.grey[400] : Colors.grey[800],
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              decoration: isCompleted ? TextDecoration.lineThrough : null,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSlot(int hour, Color backgroundColor, String plan, Color planColor, bool isPast, bool isCurrent, bool isPastDate, bool isSleepHour) {
    final dateKey = _dateKey(_selectedDate);
    final now = DateTime.now();
    final currentMinute = now.minute;
    final currentHourNow = now.hour;
    final today = DateTime(now.year, now.month, now.day);
    final selectedDay = DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day);
    final isToday = today.isAtSameMomentAs(selectedDay);
    final dayPlans = _allPlans[dateKey] ?? {};
    final planData = dayPlans[hour];
    final isCompleted = planData?['completed'] ?? false;
    
    double progressValue = 0;
    if (isToday && hour == currentHourNow) {
      progressValue = currentMinute / 60;
    }
    
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: plan.isNotEmpty ? planColor.withOpacity(0.08) : (_isDarkMode ? const Color(0xFF334155) : Colors.white),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Stack(
        children: [
          if (progressValue > 0)
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: progressValue,
                  child: Container(
                    decoration: BoxDecoration(
                      color: planColor.withOpacity(0.2),
                    ),
                  ),
                ),
              ),
            ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                tileColor: Colors.transparent,
                contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                leading: Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        planColor.withOpacity(0.1),
                        planColor.withOpacity(0.2),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: planColor.withOpacity(0.2),
                      width: 1.5,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '${hour.toString().padLeft(2, '0')}:00',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      color: planColor,
                    ),
                  ),
                ),
                title: Row(
                  children: [
                    if (plan.isNotEmpty)
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            final plans = _allPlans[dateKey];
                            if (plans != null && plans[hour] != null) {
                              plans[hour]!['completed'] = !isCompleted;
                              _savePlans();
                            }
                          });
                        },
                        child: Container(
                          width: 24,
                          height: 24,
                          margin: const EdgeInsets.only(right: 12),
                          decoration: BoxDecoration(
                            color: isCompleted ? planColor : Colors.transparent,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: planColor,
                              width: 2,
                            ),
                          ),
                          child: isCompleted
                              ? const Icon(Icons.check, color: Colors.white, size: 16)
                              : null,
                        ),
                      ),
                    Expanded(
                      child: Text(
                        isPast && plan.isEmpty ? '--' : (plan.isEmpty ? 'Plan ekle' : plan),
                        style: TextStyle(
                          color: plan.isEmpty 
                              ? (isPast ? Colors.grey[400] : Colors.grey[600])
                              : (isCompleted ? Colors.grey[400] : (_isDarkMode ? Colors.white : Colors.grey[800])),
                          fontSize: 17,
                          fontWeight: plan.isEmpty ? FontWeight.w400 : FontWeight.w600,
                          fontStyle: plan.isEmpty && !isPast ? FontStyle.italic : FontStyle.normal,
                          decoration: isCompleted ? TextDecoration.lineThrough : null,
                        ),
                        textDirection: TextDirection.ltr,
                      ),
                    ),
                  ],
                ),
                trailing: isPast
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isSleepHour) 
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.purple.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(Icons.bedtime_rounded, color: Colors.purple, size: 20),
                            ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.grey.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(Icons.lock_outline_rounded, color: Colors.grey, size: 20),
                          ),
                        ],
                      )
                    : Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: planColor.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: planColor.withOpacity(0.2),
                            width: 1,
                          ),
                        ),
                        child: Icon(Icons.edit_outlined, color: planColor, size: 20),
                      ),
                onTap: isPast
                    ? (isSleepHour
                        ? () {
                            setState(() {
                              if (!_allPlans.containsKey(dateKey)) {
                                _allPlans[dateKey] = {};
                              }
                              _allPlans[dateKey]![hour] = {'text': 'Uyku', 'color': Colors.purple};
                              _savePlans();
                            });
                          }
                        : null)
                    : (isSleepHour
                        ? () {
                            setState(() {
                              if (!_allPlans.containsKey(dateKey)) {
                                _allPlans[dateKey] = {};
                              }
                              _allPlans[dateKey]![hour] = {'text': 'Uyku', 'color': Colors.purple};
                              _savePlans();
                            });
                          }
                        : () {
                            setState(() {
                              _editingHour = hour;
                            });
                          }),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEditingSlot(int hour, Color backgroundColor, Map<int, Map<String, dynamic>> dayPlans) {
    final planData = dayPlans[hour];
    final controller = TextEditingController(text: planData?['text'] ?? '');
    final colorValue = planData?['color'];
    Color selectedColor = colorValue is Color 
        ? colorValue 
        : (colorValue is int ? Color(colorValue) : const Color(0xFF3B82F6));
    String selectedPriority = planData?['priority'] ?? 'medium';
    String selectedRepeat = planData?['repeat'] ?? 'none';
    List<String> selectedReminders = List<String>.from(planData?['reminders'] ?? []);
    final dateKey = _dateKey(_selectedDate);

    void savePlan() {
      if (controller.text.trim().isNotEmpty) {
        if (!_allPlans.containsKey(dateKey)) {
          _allPlans[dateKey] = {};
        }
        _allPlans[dateKey]![hour] = {
          'text': controller.text.trim(),
          'color': selectedColor,
          'priority': selectedPriority,
          'repeat': selectedRepeat,
          'reminders': selectedReminders,
        };
      } else {
        if (_allPlans.containsKey(dateKey)) {
          _allPlans[dateKey]!.remove(hour);
        }
      }
    }

    return GestureDetector(
      onTap: () {},
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: _isDarkMode ? const Color(0xFF334155) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${hour.toString().padLeft(2, '0')}:00',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        color: Colors.blue,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.close, color: Colors.grey, size: 20),
                      onPressed: () {
                        setState(() {
                          _editingHour = null;
                        });
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Directionality(
                textDirection: TextDirection.ltr,
                child: TextField(
                  controller: controller,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF1F2937),
                  ),
                  decoration: InputDecoration(
                    hintText: 'Ne yapmayı planlıyorsun?',
                    hintStyle: TextStyle(
                      color: Colors.grey[400],
                      fontWeight: FontWeight.w400,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    fillColor: Colors.grey[50],
                    contentPadding: const EdgeInsets.all(16),
                  ),
                  maxLines: 3,
                  autofocus: true,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  GestureDetector(
                    onTap: () => _showColorPickerDialog(selectedColor, (color) {
                      setState(() {
                        _selectedColor = color;
                        selectedColor = color;
                        savePlan();
                        _savePlans();
                      });
                    }),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: selectedColor,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: Colors.grey[300]!,
                          width: 2,
                        ),
                      ),
                      child: const Icon(Icons.palette, color: Colors.white, size: 20),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => _showPriorityPickerDialog(selectedPriority, (priority) {
                      setState(() {
                        selectedPriority = priority;
                        savePlan();
                        _savePlans();
                      });
                    }),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: _getPriorityColor(selectedPriority),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: Colors.grey[300]!,
                          width: 2,
                        ),
                      ),
                      child: const Icon(Icons.flag, color: Colors.white, size: 20),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => _showRepeatPickerDialog(selectedRepeat, (repeat) {
                      setState(() {
                        selectedRepeat = repeat;
                        savePlan();
                        _savePlans();
                      });
                    }),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: _getRepeatColor(selectedRepeat),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: Colors.grey[300]!,
                          width: 2,
                        ),
                      ),
                      child: const Icon(Icons.repeat, color: Colors.white, size: 20),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => _showReminderPickerDialog(selectedReminders, (reminders) {
                      setState(() {
                        selectedReminders = reminders;
                        savePlan();
                        _savePlans();
                      });
                    }),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: selectedReminders.isNotEmpty ? Colors.orange : Colors.grey[100],
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: Colors.grey[300]!,
                          width: 2,
                        ),
                      ),
                      child: Icon(
                        Icons.notifications,
                        color: selectedReminders.isNotEmpty ? Colors.white : const Color(0xFF4B5563),
                        size: 20,
                      ),
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        savePlan();
                        _savePlans();
                        _editingHour = null;
                      });
                    },
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [selectedColor, selectedColor.withOpacity(0.8)],
                        ),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: Colors.grey[300]!,
                          width: 2,
                        ),
                      ),
                      child: const Icon(Icons.save_rounded, color: Colors.white, size: 20),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    const months = [
      'Ocak', 'Şubat', 'Mart', 'Nisan', 'Mayıs', 'Haziran',
      'Temmuz', 'Ağustos', 'Eylül', 'Ekim', 'Kasım', 'Aralık'
    ];
    const days = ['Pazartesi', 'Salı', 'Çarşamba', 'Perşembe', 'Cuma', 'Cumartesi', 'Pazar'];
    
    return '${date.day} ${months[date.month - 1]} ${date.year}, ${days[date.weekday - 1]}';
  }

  Color _getPriorityColor(String priority) {
    final colors = {
      'high': const Color(0xFFEF4444),
      'medium': const Color(0xFFF59E0B),
      'low': const Color(0xFF10B981),
      'none': Colors.grey[300],
    };
    return colors[priority] ?? Colors.grey[300]!;
  }

  Color _getRepeatColor(String repeat) {
    if (repeat == 'none') return Colors.grey[300]!;
    return Colors.purple;
  }

  void _showColorPickerDialog(Color selectedColor, Function(Color) onColorSelected) {
    final colors = [
      Colors.blue,
      const Color(0xFFEF4444),
      const Color(0xFF10B981),
      const Color(0xFFF59E0B),
      const Color(0xFF8B5CF6),
      const Color(0xFFEC4899),
      const Color(0xFF06B6D4),
      const Color(0xFF6366F1),
      const Color(0xFF84CC16),
      const Color(0xFF64748B),
      const Color(0xFFDC2626),
      const Color(0xFF0891B2),
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(24),
            topRight: Radius.circular(24),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Renk Seç',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1E293B),
                  ),
                ),
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(Icons.close, size: 18, color: Color(0xFF6B7280)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            GridView.builder(
              shrinkWrap: true,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 1,
              ),
              itemCount: colors.length,
              itemBuilder: (context, index) {
                final color = colors[index];
                return GestureDetector(
                  onTap: () {
                    onColorSelected(color);
                    Navigator.pop(context);
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: selectedColor == color ? Colors.white : Colors.transparent,
                        width: 3,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: color.withOpacity(0.3),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: selectedColor == color
                        ? const Icon(Icons.check_rounded, color: Colors.white, size: 24)
                        : null,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showPriorityPickerDialog(String selectedPriority, Function(String) onPrioritySelected) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(24),
            topRight: Radius.circular(24),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Öncelik Seç',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1E293B),
                  ),
                ),
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(Icons.close, size: 18, color: Color(0xFF6B7280)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.maxFinite,
              child: _buildPriorityOption('high', selectedPriority, (priority) {
                onPrioritySelected(priority);
                Navigator.pop(context);
              }),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.maxFinite,
              child: _buildPriorityOption('medium', selectedPriority, (priority) {
                onPrioritySelected(priority);
                Navigator.pop(context);
              }),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.maxFinite,
              child: _buildPriorityOption('low', selectedPriority, (priority) {
                onPrioritySelected(priority);
                Navigator.pop(context);
              }),
            ),
          ],
        ),
      ),
    );
  }

  void _showRepeatPickerDialog(String selectedRepeat, Function(String) onRepeatSelected) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(24),
            topRight: Radius.circular(24),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Tekrar Seç',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1E293B),
                  ),
                ),
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(Icons.close, size: 18, color: Color(0xFF6B7280)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.maxFinite,
              child: _buildRepeatOption('none', selectedRepeat, (repeat) {
                onRepeatSelected(repeat);
                Navigator.pop(context);
              }),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.maxFinite,
              child: _buildRepeatOption('daily', selectedRepeat, (repeat) {
                onRepeatSelected(repeat);
                Navigator.pop(context);
              }),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.maxFinite,
              child: _buildRepeatOption('weekly', selectedRepeat, (repeat) {
                onRepeatSelected(repeat);
                Navigator.pop(context);
              }),
            ),
          ],
        ),
      ),
    );
  }

  void _showReminderPickerDialog(List<String> selectedReminders, Function(List<String>) onRemindersSelected) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(24),
            topRight: Radius.circular(24),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Hatırlatma Seç',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1E293B),
                  ),
                ),
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(Icons.close, size: 18, color: Color(0xFF6B7280)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.maxFinite,
              child: _buildReminderOption('15 dk', selectedReminders, (reminders) {
                onRemindersSelected(reminders);
              }),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.maxFinite,
              child: _buildReminderOption('30 dk', selectedReminders, (reminders) {
                onRemindersSelected(reminders);
              }),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.maxFinite,
              child: _buildReminderOption('60 dk', selectedReminders, (reminders) {
                onRemindersSelected(reminders);
              }),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.maxFinite,
              child: ElevatedButton(
                onPressed: () {
                  onRemindersSelected(selectedReminders);
                  Navigator.pop(context);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  'Tamam',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPriorityOption(String priority, String selectedPriority, Function(String) onTap) {
    final colors = {
      'high': const Color(0xFFEF4444),
      'medium': const Color(0xFFF59E0B),
      'low': const Color(0xFF10B981),
    };
    final labels = {
      'high': 'Yüksek',
      'medium': 'Orta',
      'low': 'Düşük',
    };
    return GestureDetector(
      onTap: () => onTap(priority),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: selectedPriority == priority ? colors[priority]! : Colors.grey[100],
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selectedPriority == priority ? colors[priority]! : Colors.grey[300]!,
            width: 2,
          ),
        ),
        child: Text(
          labels[priority]!,
          style: TextStyle(
            color: selectedPriority == priority ? Colors.white : Colors.grey[700],
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
      ),
    );
  }

  Widget _buildRepeatOption(String repeat, String selectedRepeat, Function(String) onTap) {
    final labels = {
      'none': 'Tekrar yok',
      'daily': 'Günlük',
      'weekly': 'Haftalık',
    };
    return GestureDetector(
      onTap: () => onTap(repeat),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: selectedRepeat == repeat ? Colors.purple.withOpacity(0.1) : Colors.grey[100],
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selectedRepeat == repeat ? Colors.purple.withOpacity(0.3) : Colors.grey[300]!,
            width: 2,
          ),
        ),
        child: Text(
          labels[repeat]!,
          style: TextStyle(
            color: selectedRepeat == repeat ? Colors.purple : Colors.grey[700],
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
      ),
    );
  }

  Widget _buildReminderOption(String reminder, List<String> selectedReminders, Function(List<String>) onTap) {
    final isSelected = selectedReminders.contains(reminder);
    return GestureDetector(
      onTap: () {
        final newReminders = List<String>.from(selectedReminders);
        if (isSelected) {
          newReminders.remove(reminder);
        } else {
          newReminders.add(reminder);
        }
        onTap(newReminders);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? Colors.orange.withOpacity(0.1) : Colors.grey[100],
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? Colors.orange.withOpacity(0.3) : Colors.grey[300]!,
            width: 2,
          ),
        ),
        child: Row(
          children: [
            Icon(
              isSelected ? Icons.check_circle : Icons.circle_outlined,
              color: isSelected ? Colors.orange : Colors.grey,
              size: 20,
            ),
            const SizedBox(width: 8),
            Text(
              reminder,
              style: TextStyle(
                color: isSelected ? Colors.orange : Colors.grey[700],
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _dateKey(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  void _showStatisticsDialog() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    
    // Calculate weekly statistics
    int weeklyTotal = 0;
    int weeklyCompleted = 0;
    for (int i = 0; i < 7; i++) {
      final date = today.subtract(Duration(days: i));
      final dateKey = _dateKey(date);
      final dayPlans = _allPlans[dateKey] ?? {};
      weeklyTotal += dayPlans.length;
      weeklyCompleted += dayPlans.values.where((plan) => plan['completed'] == true).length;
    }
    
    // Calculate monthly statistics
    int monthlyTotal = 0;
    int monthlyCompleted = 0;
    for (int i = 0; i < 30; i++) {
      final date = today.subtract(Duration(days: i));
      final dateKey = _dateKey(date);
      final dayPlans = _allPlans[dateKey] ?? {};
      monthlyTotal += dayPlans.length;
      monthlyCompleted += dayPlans.values.where((plan) => plan['completed'] == true).length;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(
          'İstatistikler',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 20,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Haftalık',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      color: Colors.blue,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Tamamlanan: $weeklyCompleted/$weeklyTotal',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        weeklyTotal > 0 ? '%${((weeklyCompleted / weeklyTotal) * 100).toStringAsFixed(0)}' : '%0',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Colors.blue,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: weeklyTotal > 0 ? weeklyCompleted / weeklyTotal : 0,
                      backgroundColor: Colors.blue.withOpacity(0.2),
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                      minHeight: 8,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Aylık',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      color: Colors.green,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Tamamlanan: $monthlyCompleted/$monthlyTotal',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        monthlyTotal > 0 ? '%${((monthlyCompleted / monthlyTotal) * 100).toStringAsFixed(0)}' : '%0',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Colors.green,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: monthlyTotal > 0 ? monthlyCompleted / monthlyTotal : 0,
                      backgroundColor: Colors.green.withOpacity(0.2),
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.green),
                      minHeight: 8,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Kapat',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: Colors.blue,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showSearchDialog() {
    final searchController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(
          'Plan Ara',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 20,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: searchController,
              decoration: InputDecoration(
                hintText: 'Plan adı girin...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
                fillColor: Colors.grey[100],
              ),
              onChanged: (value) {
                setState(() {});
              },
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 300,
              width: double.maxFinite,
              child: StatefulBuilder(
                builder: (context, setDialogState) {
                  final query = searchController.text.toLowerCase();
                  final results = <Map<String, dynamic>>[];

                  if (query.isNotEmpty) {
                    _allPlans.forEach((dateKey, hours) {
                      final dateParts = dateKey.split('-');
                      final date = DateTime(
                        int.parse(dateParts[0]),
                        int.parse(dateParts[1]),
                        int.parse(dateParts[2]),
                      );

                      hours.forEach((hour, planData) {
                        final text = planData['text']?.toString().toLowerCase() ?? '';
                        if (text.contains(query)) {
                          results.add({
                            'date': date,
                            'hour': hour,
                            'plan': planData,
                          });
                        }
                      });
                    });
                  }

                  if (query.isEmpty) {
                    return const Center(
                      child: Text(
                        'Aramak için bir kelime girin',
                        style: TextStyle(color: Colors.grey),
                      ),
                    );
                  }

                  if (results.isEmpty) {
                    return const Center(
                      child: Text(
                        'Sonuç bulunamadı',
                        style: TextStyle(color: Colors.grey),
                      ),
                    );
                  }

                  return ListView.builder(
                    itemCount: results.length,
                    itemBuilder: (context, index) {
                      final result = results[index];
                      final date = result['date'] as DateTime;
                      final hour = result['hour'] as int;
                      final plan = result['plan'] as Map<String, dynamic>;
                      final colorValue = plan['color'];
                      final planColor = colorValue is Color 
                          ? colorValue 
                          : (colorValue is int ? Color(colorValue) : const Color(0xFF3B82F6));

                      return ListTile(
                        leading: Container(
                          width: 50,
                          height: 50,
                          decoration: BoxDecoration(
                            color: planColor.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            '${hour.toString().padLeft(2, '0')}:00',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                              color: planColor,
                            ),
                          ),
                        ),
                        title: Text(plan['text'] ?? ''),
                        subtitle: Text(_formatDate(date)),
                        onTap: () {
                          setState(() {
                            _selectedDate = date;
                          });
                          Navigator.pop(context);
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Kapat',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: Colors.blue,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _exportPlans() {
    final exportData = <String, dynamic>{};
    _allPlans.forEach((dateKey, hours) {
      exportData[dateKey] = {};
      hours.forEach((hour, planData) {
        exportData[dateKey][hour.toString()] = {
          'text': planData['text'],
          'color': planData['color'].value,
          'completed': planData['completed'] ?? false,
          'priority': planData['priority'] ?? 'medium',
          'repeat': planData['repeat'] ?? 'none',
        };
      });
    });

    final jsonString = jsonEncode(exportData);
    
    // In web, we can create a download using HTML
    final blob = html.Blob([jsonString], 'application/json');
    final url = html.Url.createObjectUrlFromBlob(blob);
    final anchor = html.AnchorElement(href: url)
      ..setAttribute('download', 'cogniplan_export_${_dateKey(DateTime.now())}.json')
      ..click();
    html.Url.revokeObjectUrl(url);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Planlar JSON olarak dışa aktarıldı'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    );
  }
}
