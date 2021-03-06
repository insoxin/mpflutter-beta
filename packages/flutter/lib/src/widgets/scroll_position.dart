// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import 'basic.dart';
import 'framework.dart';
import 'page_storage.dart';
import 'scroll_activity.dart';
import 'scroll_context.dart';
import 'scroll_metrics.dart';
import 'scroll_notification.dart';
import 'scroll_physics.dart';

export 'scroll_activity.dart' show ScrollHoldController;

/// The policy to use when applying the `alignment` parameter of
/// [ScrollPosition.ensureVisible].
enum ScrollPositionAlignmentPolicy {
  /// Use the `alignment` property of [ScrollPosition.ensureVisible] to decide
  /// where to align the visible object.
  explicit,

  /// Find the bottom edge of the scroll container, and scroll the container, if
  /// necessary, to show the bottom of the object.
  ///
  /// For example, find the bottom edge of the scroll container. If the bottom
  /// edge of the item is below the bottom edge of the scroll container, scroll
  /// the item so that the bottom of the item is just visible. If the entire
  /// item is already visible, then do nothing.
  keepVisibleAtEnd,

  /// Find the top edge of the scroll container, and scroll the container if
  /// necessary to show the top of the object.
  ///
  /// For example, find the top edge of the scroll container. If the top edge of
  /// the item is above the top edge of the scroll container, scroll the item so
  /// that the top of the item is just visible. If the entire item is already
  /// visible, then do nothing.
  keepVisibleAtStart,
}

/// Determines which portion of the content is visible in a scroll view.
///
/// The [pixels] value determines the scroll offset that the scroll view uses to
/// select which part of its content to display. As the user scrolls the
/// viewport, this value changes, which changes the content that is displayed.
///
/// The [ScrollPosition] applies [physics] to scrolling, and stores the
/// [minScrollExtent] and [maxScrollExtent].
///
/// Scrolling is controlled by the current [activity], which is set by
/// [beginActivity]. [ScrollPosition] itself does not start any activities.
/// Instead, concrete subclasses, such as [ScrollPositionWithSingleContext],
/// typically start activities in response to user input or instructions from a
/// [ScrollController].
///
/// This object is a [Listenable] that notifies its listeners when [pixels]
/// changes.
///
/// ## Subclassing ScrollPosition
///
/// Over time, a [Scrollable] might have many different [ScrollPosition]
/// objects. For example, if [Scrollable.physics] changes type, [Scrollable]
/// creates a new [ScrollPosition] with the new physics. To transfer state from
/// the old instance to the new instance, subclasses implement [absorb]. See
/// [absorb] for more details.
///
/// Subclasses also need to call [didUpdateScrollDirection] whenever
/// [userScrollDirection] changes values.
///
/// See also:
///
///  * [Scrollable], which uses a [ScrollPosition] to determine which portion of
///    its content to display.
///  * [ScrollController], which can be used with [ListView], [GridView] and
///    other scrollable widgets to control a [ScrollPosition].
///  * [ScrollPositionWithSingleContext], which is the most commonly used
///    concrete subclass of [ScrollPosition].
///  * [ScrollNotification] and [NotificationListener], which can be used to watch
///    the scroll position without using a [ScrollController].
abstract class ScrollPosition extends ViewportOffset with ScrollMetrics {
  /// Creates an object that determines which portion of the content is visible
  /// in a scroll view.
  ///
  /// The [physics], [context], and [keepScrollOffset] parameters must not be null.
  ScrollPosition({
    required this.physics,
    this.context,
    this.keepScrollOffset = true,
    ScrollPosition? oldPosition,
    this.debugLabel,
  })  : assert(physics != null),
        assert(keepScrollOffset != null) {
    if (oldPosition != null) absorb(oldPosition);
    if (keepScrollOffset) restoreScrollOffset();
  }

  /// How the scroll position should respond to user input.
  ///
  /// For example, determines how the widget continues to animate after the
  /// user stops dragging the scroll view.
  final ScrollPhysics physics;

  /// Where the scrolling is taking place.
  ///
  /// Typically implemented by [ScrollableState].
  final ScrollContext? context;

  /// Save the current scroll offset with [PageStorage] and restore it if
  /// this scroll position's scrollable is recreated.
  ///
  /// See also:
  ///
  ///  * [ScrollController.keepScrollOffset] and [PageController.keepPage], which
  ///    create scroll positions and initialize this property.
  // TODO(goderbauer): Deprecate this when state restoration supports all features of PageStorage.
  final bool keepScrollOffset;

  /// A label that is used in the [toString] output.
  ///
  /// Intended to aid with identifying animation controller instances in debug
  /// output.
  final String? debugLabel;

  @override
  double get minScrollExtent => _minScrollExtent!;
  double? _minScrollExtent;

  @override
  double get maxScrollExtent => _maxScrollExtent!;
  double? _maxScrollExtent;

  @override
  bool get hasContentDimensions =>
      _minScrollExtent != null && _maxScrollExtent != null;

  /// The additional velocity added for a [forcePixels] change in a single
  /// frame.
  ///
  /// This value is used by [recommendDeferredLoading] in addition to the
  /// [activity]'s [ScrollActivity.velocity] to ask the [physics] whether or
  /// not to defer loading. It accounts for the fact that a [forcePixels] call
  /// may involve a [ScrollActivity] with 0 velocity, but the scrollable is
  /// still instantaneously moving from its current position to a potentially
  /// very far position, and which is of interest to callers of
  /// [recommendDeferredLoading].
  ///
  /// For example, if a scrollable is currently at 5000 pixels, and we [jumpTo]
  /// 0 to get back to the top of the list, we would have an implied velocity of
  /// -5000 and an `activity.velocity` of 0. The jump may be going past a
  /// number of resource intensive widgets which should avoid doing work if the
  /// position jumps past them.
  double _impliedVelocity = 0;

  @override
  double get pixels => 0.0;
  double? _pixels;

  @override
  bool get hasPixels => _pixels != null;

  @override
  double get viewportDimension => _viewportDimension!;
  double? _viewportDimension;

  @override
  bool get hasViewportDimension => _viewportDimension != null;

  /// Whether [viewportDimension], [minScrollExtent], [maxScrollExtent],
  /// [outOfRange], and [atEdge] are available.
  ///
  /// Set to true just before the first time [applyNewDimensions] is called.
  bool get haveDimensions => _haveDimensions;
  bool _haveDimensions = false;

  /// Take any current applicable state from the given [ScrollPosition].
  ///
  /// This method is called by the constructor if it is given an `oldPosition`.
  /// The `other` argument might not have the same [runtimeType] as this object.
  ///
  /// This method can be destructive to the other [ScrollPosition]. The other
  /// object must be disposed immediately after this call (in the same call
  /// stack, before microtask resolution, by whomever called this object's
  /// constructor).
  ///
  /// If the old [ScrollPosition] object is a different [runtimeType] than this
  /// one, the [ScrollActivity.resetActivity] method is invoked on the newly
  /// adopted [ScrollActivity].
  ///
  /// ## Overriding
  ///
  /// Overrides of this method must call `super.absorb` after setting any
  /// metrics-related or activity-related state, since this method may restart
  /// the activity and scroll activities tend to use those metrics when being
  /// restarted.
  ///
  /// Overrides of this method might need to start an [IdleScrollActivity] if
  /// they are unable to absorb the activity from the other [ScrollPosition].
  ///
  /// Overrides of this method might also need to update the delegates of
  /// absorbed scroll activities if they use themselves as a
  /// [ScrollActivityDelegate].
  @protected
  @mustCallSuper
  void absorb(ScrollPosition other) {}

  /// Update the scroll position ([pixels]) to a given pixel value.
  ///
  /// This should only be called by the current [ScrollActivity], either during
  /// the transient callback phase or in response to user input.
  ///
  /// Returns the overscroll, if any. If the return value is 0.0, that means
  /// that [pixels] now returns the given `value`. If the return value is
  /// positive, then [pixels] is less than the requested `value` by the given
  /// amount (overscroll past the max extent), and if it is negative, it is
  /// greater than the requested `value` by the given amount (underscroll past
  /// the min extent).
  ///
  /// The amount of overscroll is computed by [applyBoundaryConditions].
  ///
  /// The amount of the change that is applied is reported using [didUpdateScrollPositionBy].
  /// If there is any overscroll, it is reported using [didOverscrollBy].
  double setPixels(double newPixels) {
    return 0.0;
  }

  /// Change the value of [pixels] to the new value, without notifying any
  /// customers.
  ///
  /// This is used to adjust the position while doing layout. In particular,
  /// this is typically called as a response to [applyViewportDimension] or
  /// [applyContentDimensions] (in both cases, if this method is called, those
  /// methods should then return false to indicate that the position has been
  /// adjusted).
  ///
  /// Calling this is rarely correct in other contexts. It will not immediately
  /// cause the rendering to change, since it does not notify the widgets or
  /// render objects that might be listening to this object: they will only
  /// change when they next read the value, which could be arbitrarily later. It
  /// is generally only appropriate in the very specific case of the value being
  /// corrected during layout (since then the value is immediately read), in the
  /// specific case of a [ScrollPosition] with a single viewport customer.
  ///
  /// To cause the position to jump or animate to a new value, consider [jumpTo]
  /// or [animateTo], which will honor the normal conventions for changing the
  /// scroll offset.
  ///
  /// To force the [pixels] to a particular value without honoring the normal
  /// conventions for changing the scroll offset, consider [forcePixels]. (But
  /// see the discussion there for why that might still be a bad idea.)
  ///
  /// See also:
  ///
  ///  * [correctBy], which is a method of [ViewportOffset] used
  ///    by viewport render objects to correct the offset during layout
  ///    without notifying its listeners.
  ///  * [jumpTo], for making changes to position while not in the
  ///    middle of layout and applying the new position immediately.
  ///  * [animateTo], which is like [jumpTo] but animating to the
  ///    destination offset.
  void correctPixels(double value) {}

  /// Apply a layout-time correction to the scroll offset.
  ///
  /// This method should change the [pixels] value by `correction`, but without
  /// calling [notifyListeners]. It is called during layout by the
  /// [RenderViewport], before [applyContentDimensions]. After this method is
  /// called, the layout will be recomputed and that may result in this method
  /// being called again, though this should be very rare.
  ///
  /// See also:
  ///
  ///  * [jumpTo], for also changing the scroll position when not in layout.
  ///    [jumpTo] applies the change immediately and notifies its listeners.
  ///  * [correctPixels], which is used by the [ScrollPosition] itself to
  ///    set the offset initially during construction or after
  ///    [applyViewportDimension] or [applyContentDimensions] is called.
  @override
  void correctBy(double correction) {}

  /// Change the value of [pixels] to the new value, and notify any customers,
  /// but without honoring normal conventions for changing the scroll offset.
  ///
  /// This is used to implement [jumpTo]. It can also be used adjust the
  /// position when the dimensions of the viewport change. It should only be
  /// used when manually implementing the logic for honoring the relevant
  /// conventions of the class. For example, [ScrollPositionWithSingleContext]
  /// introduces [ScrollActivity] objects and uses [forcePixels] in conjunction
  /// with adjusting the activity, e.g. by calling
  /// [ScrollPositionWithSingleContext.goIdle], so that the activity does
  /// not immediately set the value back. (Consider, for instance, a case where
  /// one is using a [DrivenScrollActivity]. That object will ignore any calls
  /// to [forcePixels], which would result in the rendering stuttering: changing
  /// in response to [forcePixels], and then changing back to the next value
  /// derived from the animation.)
  ///
  /// To cause the position to jump or animate to a new value, consider [jumpTo]
  /// or [animateTo].
  ///
  /// This should not be called during layout (e.g. when setting the initial
  /// scroll offset). Consider [correctPixels] if you find you need to adjust
  /// the position during layout.
  @protected
  void forcePixels(double value) {}

  /// Called whenever scrolling ends, to store the current scroll offset in a
  /// storage mechanism with a lifetime that matches the app's lifetime.
  ///
  /// The stored value will be used by [restoreScrollOffset] when the
  /// [ScrollPosition] is recreated, in the case of the [Scrollable] being
  /// disposed then recreated in the same session. This might happen, for
  /// instance, if a [ListView] is on one of the pages inside a [TabBarView],
  /// and that page is displayed, then hidden, then displayed again.
  ///
  /// The default implementation writes the [pixels] using the nearest
  /// [PageStorage] found from the [context]'s [ScrollContext.storageContext]
  /// property.
  // TODO(goderbauer): Deprecate this when state restoration supports all features of PageStorage.
  @protected
  void saveScrollOffset() {}

  /// Called whenever the [ScrollPosition] is created, to restore the scroll
  /// offset if possible.
  ///
  /// The value is stored by [saveScrollOffset] when the scroll position
  /// changes, so that it can be restored in the case of the [Scrollable] being
  /// disposed then recreated in the same session. This might happen, for
  /// instance, if a [ListView] is on one of the pages inside a [TabBarView],
  /// and that page is displayed, then hidden, then displayed again.
  ///
  /// The default implementation reads the value from the nearest [PageStorage]
  /// found from the [context]'s [ScrollContext.storageContext] property, and
  /// sets it using [correctPixels], if [pixels] is still null.
  ///
  /// This method is called from the constructor, so layout has not yet
  /// occurred, and the viewport dimensions aren't yet known when it is called.
  // TODO(goderbauer): Deprecate this when state restoration supports all features of PageStorage.
  @protected
  void restoreScrollOffset() {}

  /// Called by [context] to restore the scroll offset to the provided value.
  ///
  /// The provided value has previously been provided to the [context] by
  /// calling [ScrollContext.saveOffset], e.g. from [saveOffset].
  ///
  /// This method may be called right after the scroll position is created
  /// before layout has occurred. In that case, `initialRestore` is set to true
  /// and the viewport dimensions will not be known yet. If the [context]
  /// doesn't have any information to restore the scroll offset this method is
  /// not called.
  ///
  /// The method may be called multiple times in the lifecycle of a
  /// [ScrollPosition] to restore it to different scroll offsets.
  void restoreOffset(double offset, {bool initialRestore = false}) {}

  /// Called whenever scrolling ends, to persist the current scroll offset for
  /// state restoration purposes.
  ///
  /// The default implementation stores the current value of [pixels] on the
  /// [context] by calling [ScrollContext.saveOffset]. At a later point in time
  /// or after the application restarts, the [context] may restore the scroll
  /// position to the persisted offset by calling [restoreOffset].
  @protected
  void saveOffset() {}

  /// Returns the overscroll by applying the boundary conditions.
  ///
  /// If the given value is in bounds, returns 0.0. Otherwise, returns the
  /// amount of value that cannot be applied to [pixels] as a result of the
  /// boundary conditions. If the [physics] allow out-of-bounds scrolling, this
  /// method always returns 0.0.
  ///
  /// The default implementation defers to the [physics] object's
  /// [ScrollPhysics.applyBoundaryConditions].
  @protected
  double applyBoundaryConditions(double value) {
    return 0.0;
  }

  bool _didChangeViewportDimensionOrReceiveCorrection = true;

  @override
  bool applyViewportDimension(double viewportDimension) {
    return true;
  }

  bool _pendingDimensions = false;
  ScrollMetrics? _lastMetrics;

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    return true;
  }

  /// Verifies that the new content and viewport dimensions are acceptable.
  ///
  /// Called by [applyContentDimensions] to determine its return value.
  ///
  /// Should return true if the current scroll offset is correct given
  /// the new content and viewport dimensions.
  ///
  /// Otherwise, should call [correctPixels] to correct the scroll
  /// offset given the new dimensions, and then return false.
  ///
  /// This is only called when [haveDimensions] is true.
  ///
  /// The default implementation defers to [ScrollPhysics.adjustPositionForNewDimensions].
  @protected
  bool correctForNewDimensions(
      ScrollMetrics oldPosition, ScrollMetrics newPosition) {
    return true;
  }

  /// Notifies the activity that the dimensions of the underlying viewport or
  /// contents have changed.
  ///
  /// Called after [applyViewportDimension] or [applyContentDimensions] have
  /// changed the [minScrollExtent], the [maxScrollExtent], or the
  /// [viewportDimension]. When this method is called, it should be called
  /// _after_ any corrections are applied to [pixels] using [correctPixels], not
  /// before.
  ///
  /// The default implementation informs the [activity] of the new dimensions by
  /// calling its [ScrollActivity.applyNewDimensions] method.
  ///
  /// See also:
  ///
  ///  * [applyViewportDimension], which is called when new
  ///    viewport dimensions are established.
  ///  * [applyContentDimensions], which is called after new
  ///    viewport dimensions are established, and also if new content dimensions
  ///    are established, and which calls [ScrollPosition.applyNewDimensions].
  @protected
  @mustCallSuper
  void applyNewDimensions() {}

  /// Called whenever the scroll position or the dimensions of the scroll view
  /// change to schedule an update of the available semantics actions. The
  /// actual update will be performed in the next frame. If non is pending
  /// a frame will be scheduled.
  ///
  /// For example: If the scroll view has been scrolled all the way to the top,
  /// the action to scroll further up needs to be removed as the scroll view
  /// cannot be scrolled in that direction anymore.
  ///
  /// This method is potentially called twice per frame (if scroll position and
  /// scroll view dimensions both change) and therefore shouldn't do anything
  /// expensive.
  void _updateSemanticActions() {}

  /// Animates the position such that the given object is as visible as possible
  /// by just scrolling this position.
  ///
  /// The optional `targetRenderObject` parameter is used to determine which area
  /// of that object should be as visible as possible. If `targetRenderObject`
  /// is null, the entire [RenderObject] (as defined by its
  /// [RenderObject.paintBounds]) will be as visible as possible. If
  /// `targetRenderObject` is provided, it must be a descendant of the object.
  ///
  /// See also:
  ///
  ///  * [ScrollPositionAlignmentPolicy] for the way in which `alignment` is
  ///    applied, and the way the given `object` is aligned.
  Future<void> ensureVisible(
    RenderObject object, {
    double alignment = 0.0,
    Duration duration = Duration.zero,
    Curve curve = Curves.ease,
    ScrollPositionAlignmentPolicy alignmentPolicy =
        ScrollPositionAlignmentPolicy.explicit,
    RenderObject? targetRenderObject,
  }) {
    return Future.wait<void>([]).then<void>((List<void> _) => null);
  }

  /// This notifier's value is true if a scroll is underway and false if the scroll
  /// position is idle.
  ///
  /// Listeners added by stateful widgets should be removed in the widget's
  /// [State.dispose] method.
  final ValueNotifier<bool> isScrollingNotifier = ValueNotifier<bool>(false);

  /// Animates the position from its current value to the given value.
  ///
  /// Any active animation is canceled. If the user is currently scrolling, that
  /// action is canceled.
  ///
  /// The returned [Future] will complete when the animation ends, whether it
  /// completed successfully or whether it was interrupted prematurely.
  ///
  /// An animation will be interrupted whenever the user attempts to scroll
  /// manually, or whenever another activity is started, or whenever the
  /// animation reaches the edge of the viewport and attempts to overscroll. (If
  /// the [ScrollPosition] does not overscroll but instead allows scrolling
  /// beyond the extents, then going beyond the extents will not interrupt the
  /// animation.)
  ///
  /// The animation is indifferent to changes to the viewport or content
  /// dimensions.
  ///
  /// Once the animation has completed, the scroll position will attempt to
  /// begin a ballistic activity in case its value is not stable (for example,
  /// if it is scrolled beyond the extents and in that situation the scroll
  /// position would normally bounce back).
  ///
  /// The duration must not be zero. To jump to a particular value without an
  /// animation, use [jumpTo].
  ///
  /// The animation is typically handled by an [DrivenScrollActivity].
  @override
  Future<void> animateTo(
    double to, {
    required Duration duration,
    required Curve curve,
  });

  /// Jumps the scroll position from its current value to the given value,
  /// without animation, and without checking if the new value is in range.
  ///
  /// Any active animation is canceled. If the user is currently scrolling, that
  /// action is canceled.
  ///
  /// If this method changes the scroll position, a sequence of start/update/end
  /// scroll notifications will be dispatched. No overscroll notifications can
  /// be generated by this method.
  @override
  void jumpTo(double value);

  /// Changes the scrolling position based on a pointer signal from current
  /// value to delta without animation and without checking if new value is in
  /// range, taking min/max scroll extent into account.
  ///
  /// Any active animation is canceled. If the user is currently scrolling, that
  /// action is canceled.
  ///
  /// This method dispatches the start/update/end sequence of scrolling
  /// notifications.
  ///
  /// This method is very similar to [jumpTo], but [pointerScroll] will
  /// update the [ScrollDirection].
  ///
  // TODO(YeungKC): Support trackpad scroll, https://github.com/flutter/flutter/issues/23604.
  void pointerScroll(double delta);

  /// Calls [jumpTo] if duration is null or [Duration.zero], otherwise
  /// [animateTo] is called.
  ///
  /// If [clamp] is true (the default) then [to] is adjusted to prevent over or
  /// underscroll.
  ///
  /// If [animateTo] is called then [curve] defaults to [Curves.ease].
  @override
  Future<void> moveTo(
    double to, {
    Duration? duration,
    Curve? curve,
    bool? clamp = true,
  }) {
    return super.moveTo(to, duration: duration, curve: curve);
  }

  @override
  bool get allowImplicitScrolling => physics.allowImplicitScrolling;

  /// Deprecated. Use [jumpTo] or a custom [ScrollPosition] instead.
  @Deprecated(
      'This will lead to bugs.') // ignore: flutter_deprecation_syntax, https://github.com/flutter/flutter/issues/44609
  void jumpToWithoutSettling(double value);

  /// Stop the current activity and start a [HoldScrollActivity].
  ScrollHoldController hold(VoidCallback holdCancelCallback);

  /// Start a drag activity corresponding to the given [DragStartDetails].
  ///
  /// The `onDragCanceled` argument will be invoked if the drag is ended
  /// prematurely (e.g. from another activity taking over). See
  /// [ScrollDragController.onDragCanceled] for details.
  Drag drag(DragStartDetails details, VoidCallback dragCancelCallback);

  /// The currently operative [ScrollActivity].
  ///
  /// If the scroll position is not performing any more specific activity, the
  /// activity will be an [IdleScrollActivity]. To determine whether the scroll
  /// position is idle, check the [isScrollingNotifier].
  ///
  /// Call [beginActivity] to change the current activity.
  @protected
  @visibleForTesting
  ScrollActivity? get activity => _activity;
  ScrollActivity? _activity;

  /// Change the current [activity], disposing of the old one and
  /// sending scroll notifications as necessary.
  ///
  /// If the argument is null, this method has no effect. This is convenient for
  /// cases where the new activity is obtained from another method, and that
  /// method might return null, since it means the caller does not have to
  /// explicitly null-check the argument.
  void beginActivity(ScrollActivity? newActivity) {}

  // NOTIFICATION DISPATCH

  /// Called by [beginActivity] to report when an activity has started.
  void didStartScroll() {}

  /// Called by [setPixels] to report a change to the [pixels] position.
  void didUpdateScrollPositionBy(double delta) {}

  /// Called by [beginActivity] to report when an activity has ended.
  ///
  /// This also saves the scroll offset using [saveScrollOffset].
  void didEndScroll() {}

  /// Called by [setPixels] to report overscroll when an attempt is made to
  /// change the [pixels] position. Overscroll is the amount of change that was
  /// not applied to the [pixels] value.
  void didOverscrollBy(double value) {}

  /// Dispatches a notification that the [userScrollDirection] has changed.
  ///
  /// Subclasses should call this function when they change [userScrollDirection].
  void didUpdateScrollDirection(ScrollDirection direction) {}

  /// Provides a heuristic to determine if expensive frame-bound tasks should be
  /// deferred.
  ///
  /// The actual work of this is delegated to the [physics] via
  /// [ScrollPhysics.recommendDeferredLoading] called with the current
  /// [activity]'s [ScrollActivity.velocity].
  ///
  /// Returning true from this method indicates that the [ScrollPhysics]
  /// evaluate the current scroll velocity to be great enough that expensive
  /// operations impacting the UI should be deferred.
  bool recommendDeferredLoading(BuildContext context) {
    return false;
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  void notifyListeners() {
    super.notifyListeners();
  }
}
