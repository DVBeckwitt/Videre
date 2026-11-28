import 'package:bloc/bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/extensions.dart';
import 'package:clipious/offline_subscriptions/models/offline_subscription.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:logging/logging.dart';

import '../../globals.dart';
import '../models/subscription.dart';
import '../services/subscription_account.dart';

part 'manage_subscriptions.freezed.dart';

final logger = Logger('ManageSubscriptionController');

class ManageSubscriptionCubit extends Cubit<ManageSubscriptionsState> {
  ManageSubscriptionCubit(super.initialState) {
    SubscriptionAccount.revision.addListener(_accountChanged);
    onReady();
  }

  int _refreshGeneration = 0;

  void onReady() {
    refreshSubs();
  }

  void _accountChanged() {
    if (isClosed) return;
    emit(state.copyWith(subs: const [], isLoggedIn: false));
    refreshSubs();
  }

  @override
  Future<void> close() {
    SubscriptionAccount.revision.removeListener(_accountChanged);
    return super.close();
  }

  Future<void> unsubscribe(String authorId) async {
    if (isClosed) return;
    final generation = _refreshGeneration;
    final accountRevision = SubscriptionAccount.revision.value;
    final database = db;
    final profile = database.profileId;
    bool accountCurrent() =>
        SubscriptionAccount.revision.value == accountRevision &&
        identical(database, db) &&
        database.profileId == profile;
    emit(state.copyWith(loading: true, hasError: false));
    try {
      final removed = await service.unSubscribe(authorId);
      if (!accountCurrent()) return;
      final stillSubscribed =
          removed && await service.isSubscribedToChannel(authorId);
      if (!accountCurrent()) return;

      if (!removed || stillSubscribed) {
        throw InvidiousServiceError(
          'The subscription state was not updated',
        );
      }

      await refreshSubs();
    } catch (error) {
      logger.warning('Unable to unsubscribe from $authorId', error);
      if (!isClosed && generation == _refreshGeneration) {
        emit(state.copyWith(loading: false, hasError: true));
      }
      rethrow;
    }
  }

  Future<void> refreshSubs() async {
    if (isClosed) return;
    final database = db;
    final owner = database.forProfile(database.profileId);
    final generation = ++_refreshGeneration;
    bool current() =>
        !isClosed &&
        generation == _refreshGeneration &&
        identical(db, database) &&
        database.profileId == owner.profileId;
    emit(state.copyWith(loading: true, hasError: false));
    var isLoggedIn = state.isLoggedIn;
    try {
      // Local subscriptions remain available while the instance is loading or
      // unavailable. Preserve the previous account list if its refresh fails.
      final offlineSubs = await owner.getOfflineSubscriptions();
      if (!current()) return;
      emit(state.copyWith(offlineSubs: offlineSubs));
      isLoggedIn = await service.hasSubscriptionAccount();
      if (!current()) return;
      final subs = isLoggedIn
          ? (await service.getSubscriptions()).sortBy((e) => e.author).toList()
          : <Subscription>[];
      if (current()) {
        emit(
            state.copyWith(subs: subs, loading: false, isLoggedIn: isLoggedIn));
      }
    } catch (error, stackTrace) {
      logger.warning('Unable to refresh subscriptions', error, stackTrace);
      if (current()) {
        emit(state.copyWith(
            loading: false, isLoggedIn: isLoggedIn, hasError: true));
      }
    }
  }

  Future<void> unsubscribeOffline(String channelId) async {
    if (isClosed) return;
    emit(state.copyWith(loading: true, hasError: false));
    try {
      await db.deleteOfflineSubscription(channelId);
      await refreshSubs();
    } catch (error, stackTrace) {
      logger.warning('Unable to remove local subscription', error, stackTrace);
      if (!isClosed) emit(state.copyWith(loading: false, hasError: true));
      rethrow;
    }
  }
}

@freezed
sealed class ManageSubscriptionsState with _$ManageSubscriptionsState {
  const factory ManageSubscriptionsState(
      {@Default([]) List<Subscription> subs,
      @Default([]) List<OfflineSubscription> offlineSubs,
      @Default(false) bool isLoggedIn,
      @Default(false) bool hasError,
      @Default(true) bool loading}) = _ManageSubscriptionsState;
}
