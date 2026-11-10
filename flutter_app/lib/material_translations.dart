import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'i18n.dart';

/// The toolkit strings used by this app, backed by the same offline catalog.
class MaprismaMaterialDelegate extends LocalizationsDelegate<MaterialLocalizations> {
  const MaprismaMaterialDelegate();
  @override
  bool isSupported(Locale locale) => languageNames.containsKey(locale.languageCode);
  @override
  Future<MaterialLocalizations> load(Locale locale) => SynchronousFuture(_MaterialTranslations());
  @override
  bool shouldReload(MaprismaMaterialDelegate old) => false;
}

class _MaterialTranslations extends DefaultMaterialLocalizations {
  @override
  String get backButtonTooltip => tr('Back');
  @override
  String get clearButtonTooltip => tr('Clear text');
  @override
  String get closeButtonTooltip => tr('Close');
  @override
  String get deleteButtonTooltip => tr('Delete');
  @override
  String get moreButtonTooltip => tr('More');
  @override
  String get showMenuTooltip => tr('Show menu');
  @override
  String get popupMenuLabel => tr('Popup menu');
  @override
  String get menuBarMenuLabel => tr('Menu');
  @override
  String get dialogLabel => tr('Dialog');
  @override
  String get alertDialogLabel => tr('Alert');
  @override
  String get searchFieldLabel => tr('Search');
  @override
  String get cancelButtonLabel => tr('Cancel');
  @override
  String get closeButtonLabel => tr('Close');
  @override
  String get continueButtonLabel => tr('Continue');
  @override
  String get copyButtonLabel => tr('Copy');
  @override
  String get cutButtonLabel => tr('Cut');
  @override
  String get pasteButtonLabel => tr('Paste');
  @override
  String get selectAllButtonLabel => tr('Select all');
  @override
  String get okButtonLabel => tr('OK');
  @override
  String get lookUpButtonLabel => tr('Look up');
  @override
  String get searchWebButtonLabel => tr('Search web');
  @override
  String get shareButtonLabel => tr('Share');
  @override
  String get modalBarrierDismissLabel => tr('Dismiss');
  @override
  String get menuDismissLabel => tr('Dismiss menu');
  @override
  String get expandedIconTapHint => tr('Collapse');
  @override
  String get collapsedIconTapHint => tr('Expand');
  @override
  String remainingTextFieldCharacterCount(int remaining) => trf('{0} characters remaining', [remaining]);
}
