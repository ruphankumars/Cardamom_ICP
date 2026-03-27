/// Shared business constants used across the application.
/// Centralizes magic numbers to prevent inconsistencies.

/// Default packaging weights (kg) — industry standard for cardamom
const double kDefaultBagWeight = 50;
const double kDefaultBoxWeight = 20;

/// Weight multiplier for bag/box types
int? getWeightMultiplier(String? bagbox) {
  if (bagbox == null) return null;
  final lower = bagbox.toLowerCase();
  if (lower.contains('bag')) return kDefaultBagWeight.toInt();
  if (lower.contains('box')) return kDefaultBoxWeight.toInt();
  return null;
}
