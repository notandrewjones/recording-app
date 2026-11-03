# DeckLink SDK headers

`Mac/include` from the Blackmagic Desktop Video SDK 16.0, unmodified, so CI can compile the bridge without
the SDK download. The licence is at the top of each file, and the SDK EULA's clause 0 exempts these folders
from its restrictive terms. Nothing else from the SDK is in this repo.

To update, replace `Mac/include` with the same folder from the new SDK. The major version should match the
Desktop Video on the machines that run the app.
