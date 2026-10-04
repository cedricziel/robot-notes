import 'package:dart_frog/dart_frog.dart';
import 'package:server/src/vault_registry.dart';

/// Never treats a missing choice as permission for all vaults.
Set<String>? selectedVaults(RequestContext context, Map<String, String> form) {
  final ids = {
    for (final e in form.entries)
      if (e.key.startsWith('vault_') && e.value == 'yes') e.key.substring(6),
  };
  if (ids.isEmpty) return null;
  final vaults = context.read<VaultRegistry>();
  if (ids.any((id) => !vaults.contains(id))) return null;
  return ids;
}
