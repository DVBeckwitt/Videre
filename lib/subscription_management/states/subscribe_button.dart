import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/offline_subscriptions/models/offline_subscription.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:logging/logging.dart';

import '../../globals.dart';
import '../services/subscription_account.dart';

part 'subscribe_button.freezed.dart';

class SubscribeButtonCubit extends Cubit<SubscribeButtonState> {
  SubscribeButtonCubit(super.initialState) {
    SubscriptionAccount.revision.addListener(_accountChanged);
    onReady();
  }

  int _accountRevision = 0;

  void _accountChanged() {
    if (isClosed) return;
    emit(state.copyWith(
        loading: true, isLoggedIn: false, isAccountSubscribed: false));
    unawaited(onReady());
  }

  @override
  Future<void> close() {
    SubscriptionAccount.revision.removeListener(_accountChanged);
    return super.close();
  }

  Future<void> setAccountSubscription(bool subscribed) async {
    if (isClosed) return;
    emit(state.copyWith(loading: true));

    final revision = _accountRevision;
    bool current() => !isClosed && revision == _accountRevision;
    try {
      final changed = subscribed
          ? await service.subscribe(state.channelId)
          : await service.unSubscribe(state.channelId);
      if (!current()) return;
      final actual =
          changed ? await service.isSubscribedToChannel(state.channelId) : null;
      if (!current()) return;
      if (actual != subscribed) {
        throw InvidiousServiceError(
          'The subscription state was not updated',
        );
      }

      emit(state.copyWith(loading: false, isAccountSubscribed: subscribed));
    } catch (_) {
      if (current()) {
        emit(state.copyWith(loading: false));
        rethrow;
      }
    }
  }

  Future<void> setOfflineSubscription(bool subscribed) async {
    if (isClosed) return;
    final database = db;
    final owner = database.forProfile(database.profileId);
    emit(state.copyWith(loading: true));
    try {
      if (subscribed) {
        final channel = await service.getChannel(state.channelId);
        await owner.addOfflineSubscription(OfflineSubscription(
            channelId: state.channelId, channelName: channel.author));
      } else {
        await owner.deleteOfflineSubscription(state.channelId);
      }
      if (!isClosed &&
          identical(db, database) &&
          database.profileId == owner.profileId) {
        emit(state.copyWith(isOfflineSubscribed: subscribed));
      }
    } finally {
      if (!isClosed) emit(state.copyWith(loading: false));
    }
  }

  Future<void> onReady() async {
    final revision = ++_accountRevision;
    var isLoggedIn = state.isLoggedIn;
    var isAccountSubscribed = state.isAccountSubscribed;
    var isOfflineSubscribed = state.isOfflineSubscribed;
    try {
      // Local subscriptions still work when the instance is unavailable.
      isOfflineSubscribed = await db.isOfflineSubscribed(state.channelId);
      isLoggedIn = await service.hasSubscriptionAccount();
      isAccountSubscribed =
          isLoggedIn && await service.isSubscribedToChannel(state.channelId);
    } catch (error, stackTrace) {
      Logger('SubscribeButton')
          .warning('Could not load subscription status', error, stackTrace);
    }
    // The player or the subscription account may have changed during the read.
    if (isClosed || revision != _accountRevision) return;
    emit(state.copyWith(
        loading: false,
        isOfflineSubscribed: isOfflineSubscribed,
        isAccountSubscribed: isAccountSubscribed,
        isLoggedIn: isLoggedIn));
  }

  Future<void> unsubscribe() async {
    if (isClosed) return;
    emit(state.copyWith(loading: true));

    if (state.isAccountSubscribed) {
      await setAccountSubscription(false);
    }

    if (state.isOfflineSubscribed) {
      await setOfflineSubscription(false);
    }

    if (!isClosed) emit(state.copyWith(loading: false));
  }
}

@freezed
sealed class SubscribeButtonState with _$SubscribeButtonState {
  const factory SubscribeButtonState({
    required String channelId,
    @Default(false) bool isOfflineSubscribed,
    @Default(false) bool isAccountSubscribed,
    @Default(true) bool loading,
    required bool isLoggedIn,
  }) = _SubscribeButtonState;

  const SubscribeButtonState._();

  bool get isSubscribed => isOfflineSubscribed || isAccountSubscribed;

  static SubscribeButtonState init(String channelId) {
    return SubscribeButtonState(channelId: channelId, isLoggedIn: false);
  }
}
