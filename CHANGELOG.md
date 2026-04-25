# Changelog

## [3.53.0](https://github.com/ASTRACAT2022/badalaga-auto/compare/v3.52.1...v3.53.0) (2026-04-25)


### New Features

* add full safe stealthnet migration wrapper ([f25c190](https://github.com/ASTRACAT2022/badalaga-auto/commit/f25c19017d75a1e7b8f1fa6f14b6bf99373cc9fb))
* add unified local gateway for cabinet and api ([6934150](https://github.com/ASTRACAT2022/badalaga-auto/commit/693415084dee06517436a15229e44477c66913e2))
* bootstrap bedolaga stack and stealthnet auto-migration ([1cd8b4c](https://github.com/ASTRACAT2022/badalaga-auto/commit/1cd8b4c7c705fcd7622d49d935cb4d88a480a159))


### Bug Fixes

* add fallback for stealthnet dumps without secondary_subscriptions ([96ef77e](https://github.com/ASTRACAT2022/badalaga-auto/commit/96ef77e6ec59f379d251eca3d5672fcedffc9ea3))
* auto-create postgres role for dblink compatibility ([ec63266](https://github.com/ASTRACAT2022/badalaga-auto/commit/ec63266fba74d1141836fc3dedf9b6d7c6908f89))
* avoid psql var usage inside DO block in stealthnet migration ([ed838b1](https://github.com/ASTRACAT2022/badalaga-auto/commit/ed838b100610d9311d2b0093176ee66fb2874dc2))
* avoid subs_mode psql var inside subscription DO block ([33af4d1](https://github.com/ASTRACAT2022/badalaga-auto/commit/33af4d1c4474b1f556546b57926d9791f894951c))
* derive fallback subscriptions from clients and remove duplicate wrapper shim ([04acbb2](https://github.com/ASTRACAT2022/badalaga-auto/commit/04acbb20a59c782779253b324ccdb8ee88a14f96))
* ensure secondary_subscriptions compatibility in staging before migration ([6d2bde6](https://github.com/ASTRACAT2022/badalaga-auto/commit/6d2bde6d8ab355c05e9f40e8f451b5382b0de55f))
* ensure users has_had_paid_subscription default before client import ([5dd5605](https://github.com/ASTRACAT2022/badalaga-auto/commit/5dd56057440a9c7934e0500bcc006f0781ee9e0e))
* harden user import defaults for non-null fields ([7682b7c](https://github.com/ASTRACAT2022/badalaga-auto/commit/7682b7c891532b2ada842cf80bcb62ed04ed7ac2))
* restore subscription days and slots from panel sync ([f987c34](https://github.com/ASTRACAT2022/badalaga-auto/commit/f987c3487587b1efc5b01c2dd116fca74cc8c426))
* set is_daily_paused explicitly for imported subscriptions ([606d059](https://github.com/ASTRACAT2022/badalaga-auto/commit/606d059921f32661213fb3b059f2e7a094dae81b))
* set ticket user_reply_block_permanent during stealthnet import ([6feb415](https://github.com/ASTRACAT2022/badalaga-auto/commit/6feb415e54fed3cb4399768b7f1ccd29ab214a53))
* set unique remnawave_short_id when importing subscriptions ([318a87e](https://github.com/ASTRACAT2022/badalaga-auto/commit/318a87e27cbc5aab4923e3af3f7a05a428bbba83))
* strip pg18 transaction_timeout from sanitized dumps ([49406a8](https://github.com/ASTRACAT2022/badalaga-auto/commit/49406a8a138c0e4de7ae530c142b7cf869307d5c))
* sync user balances from source client map ([3f98ffd](https://github.com/ASTRACAT2022/badalaga-auto/commit/3f98ffdcdeb655808d2b768c8efedecc06f85b19))
