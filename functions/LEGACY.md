# Legacy Firebase Functions implementation

This directory is retained only as an audited reference for the previous Blaze-dependent backend. It is not referenced by `firebase.json`, is not called by the Flutter application, and must not be deployed for the Spark-plan architecture.

The production replacements live in `../worker/`:

- `generateGuestQr` → `POST /generate-guest-qr`
- `cancelGuestQr` → `POST /cancel-guest-qr`
- `generateDeliveryQr` → `POST /generate-delivery-qr`
- `validateAndUseQr` → `POST /validate-and-use-qr`

All authorization, Firestore transaction, secure-token, trusted timestamp, quota, and state-transition protections were reproduced in the Cloudflare Worker before this implementation was deprecated.
