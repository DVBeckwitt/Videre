import 'package:bloc/bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/extensions.dart';
import 'package:clipious/offline_subscriptions/models/offline_subscription.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:logging/logging.dart';

import '../../globals.dart';
import '../models/subscription.dart';

part 'manage_subscriptions.freezed.dart';

final logger = Logger('ManageSubscriptionController');

class ManageSubscriptionCubit extends Cubit<ManageSubscriptionsState> {
  ManageSubscriptionCubit(super.initialState) {
    onReady();
  }

  void onReady() {
    refreshSubs();
  }

  Future<void> unsubscribe(String authorId) async {
    emit(state.copyWith(loading: true));
    try {
      await service.unSubscribe(authorId);
      final isSubscribed = await service.isSubscribedToChannel(authorId);

      if (isSubscribed) {
        throw InvidiousServiceError(
          'The subscription state was not updated',
        );
      }

      await refreshSubs();
    } catch (error) {
      logger.warning('Unable to unsubscribe from $authorId', error);
      emit(state.copyWith(loading: false));
      rethrow;
    }
  }

  Future<void> refreshSubs() async {
    final isLoggedIn = await service.isLoggedIn();
    emit(state.copyWith(loading: true));
    List<Subscription> subs = [];
    if (isLoggedIn) {
      subs =
          (await service.getSubscriptions()).sortBy((e) => e.author).toList();
    }
    final offlineSubs = await db.getOfflineSubscriptions();
    emit(state.copyWith(
        subs: subs,
        loading: false,
        isLoggedIn: isLoggedIn,
        offlineSubs: offlineSubs));
  }

  Future<void> unsubscribeOffline(String channelId) async {
    await db.deleteOfflineSubscription(channelId);
    refreshSubs();
  }
}

@freezed
sealed class ManageSubscriptionsState with _$ManageSubscriptionsState {
  const factory ManageSubscriptionsState(
      {@Default([]) List<Subscription> subs,
      @Default([]) List<OfflineSubscription> offlineSubs,
      @Default(false) isLoggedIn,
      @Default(true) bool loading}) = _ManageSubscriptionsState;
}
