import 'package:bloc/bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/offline_subscriptions/models/offline_subscription.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';

import '../../globals.dart';

part 'subscribe_button.freezed.dart';

class SubscribeButtonCubit extends Cubit<SubscribeButtonState> {
  SubscribeButtonCubit(super.initialState) {
    onReady();
  }

  Future<void> setAccountSubscription(bool subscribed) async {
    emit(state.copyWith(loading: true));

    try {
      if (subscribed) {
        await service.subscribe(state.channelId);
      } else {
        await service.unSubscribe(state.channelId);
      }

      final actual = await service.isSubscribedToChannel(state.channelId);
      if (actual != subscribed) {
        throw InvidiousServiceError(
          'The subscription state was not updated',
        );
      }

      emit(state.copyWith(
        loading: false,
        isAccountSubscribed: actual,
      ));
    } catch (_) {
      emit(state.copyWith(loading: false));
      rethrow;
    }
  }

  Future<void> setOfflineSubscription(bool subscribed) async {
    emit(state.copyWith(loading: true));
    if (subscribed) {
      final channel = await service.getChannel(state.channelId);
      await db.addOfflineSubscription(OfflineSubscription(
          channelId: state.channelId, channelName: channel.author));
    } else {
      await db.deleteOfflineSubscription(state.channelId);
    }
    emit(state.copyWith(isOfflineSubscribed: subscribed, loading: false));
  }

  Future<void> onReady() async {
    var isLoggedIn = await service.isLoggedIn();

    bool isAccountSubscribed =
        isLoggedIn && await service.isSubscribedToChannel(state.channelId);

    bool isOfflineSubscribed = await db.isOfflineSubscribed(state.channelId);
    emit(state.copyWith(
        loading: false,
        isOfflineSubscribed: isOfflineSubscribed,
        isAccountSubscribed: isAccountSubscribed,
        isLoggedIn: isLoggedIn));
  }

  Future<void> unsubscribe() async {
    emit(state.copyWith(loading: true));

    if (state.isAccountSubscribed) {
      await setAccountSubscription(false);
    }

    if (state.isOfflineSubscribed) {
      await setOfflineSubscription(false);
    }

    emit(state.copyWith(loading: false));
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
