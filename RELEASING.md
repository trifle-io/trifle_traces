# Releasing

Trifle.Traces is distributed from GitHub tags. It is not published to Hex, and
the release process does not require a Hex account or API key.

## Release candidate

1. Choose matching Ruby and Elixir revisions. The Ruby version should be
   `2.0.0.rc1` when the Elixir version is `2.0.0-rc.1`.
2. Run the Elixir unit suite, core-only consumer, PostgreSQL/Mongo/MinIO
   integrations, generated documentation, and local archive validation.
3. Run the Ruby suite and RuboCop, including PostgreSQL, Mongo, and S3
   integrations.
4. Commit and push the compatible changes in `trifle-traces`, `trifle_traces`,
   `docs-trifle-io`, and the Trifle skills repository.
5. Tag the Ruby and Elixir repositories with `v2.0.0-rc.1`, then push both
   tags. The Elixir installation documentation depends on this tag.
6. In the Elixir repository, run the **Ruby and Elixir interoperability**
   workflow with `ruby_ref` set to `v2.0.0-rc.1`.
7. Create GitHub releases from the verified tags and deploy the documentation
   site.

GitHub Actions needs only its default repository token. PostgreSQL, Mongo, and
MinIO run as ephemeral CI services; no external service secrets are required.

## Final 2.0

After the release candidate is verified in consuming applications:

1. Change the Elixir version to `2.0.0` and the Ruby version to `2.0.0`.
2. Replace the unreleased changelog headings with the release date.
3. Update Git installation examples from the RC tag to `v2.0.0`.
4. Repeat the complete compatibility gate.
5. Push coordinated `v2.0.0` tags, rerun interoperability against the Ruby
   tag, create GitHub releases, and deploy documentation.

Do not run `mix hex.publish` and do not add a Hex publishing workflow.
