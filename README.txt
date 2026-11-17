CoolapkDisplay for the supplied CoolMarket 16.7 (build 2610231)

This repository branch builds our small Objective-C display plugin and a
synthetic UIKit test app. It contains no Coolapk application binary or IPA.

The plugin hides only four exact advertising view classes after their original
view methods run. It does not change feed data, pagination, images, networking,
identity, login, SDK validity, or ad input data. Hidden feed cells retain their
original layout space. It requests splash/interstitial dismissal through the
app's existing Skip/Close UI actions; those actions retain their original
cleanup/callbacks and occur earlier than they otherwise would.

No global UIKit hook, scrolling hook, image-decoding hook, synthetic impression
or success callback, recursive view-tree scan, or recurring timer is added.
LoadControl and MyDock are independent retained plugins, not rewritten here.

The production library supports arm64 iOS 17+. It needs to be signed together
with the app using the user's own signing certificate. The synthetic simulator
checks verify method isolation, original dispatch, image/gesture object
preservation, and close races. They do not prove Coolapk login, ad coverage,
physical-device frame rate, or server acceptance of modified applications.

Run build_and_test.py on a Mac with Xcode and an available iPhone simulator.
The GitHub workflow publishes only this library and test receipts.
