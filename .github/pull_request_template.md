## Summary

<!-- What user, contract, or maintenance outcome does this change provide? -->

## Contract impact

- [ ] No Companion API contract change
- [ ] OpenAPI, fixtures, Swift models, docs, and changelog updated together
- [ ] Minimum Tesserae compatibility changed and documented

## Verification

- [ ] `python -m pytest Contracts/test_contract.py`
- [ ] `swift test --package-path Packages/TesseraeKit`
- [ ] iOS Simulator build
- [ ] Relevant simulator UI test
- [ ] Physical iPhone/display evidence attached when claimed

## Safety

- [ ] No credentials, signing material, server addresses, or household content
- [ ] Fixture/live boundary remains explicit
- [ ] User-visible or contract changes are recorded in `CHANGELOG.md`
