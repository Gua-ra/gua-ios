#!/usr/bin/env node
//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
//

// Sends an uploaded production build to the external TestFlight group.
//
// Internal groups with access to all builds get every build automatically; external
// groups do not. Each build has to be added to the group and submitted for Beta App
// Review, and Apple notifies the group once the review passes (autoNotifyEnabled).
//
// Idempotent: a build already in the group, already submitted or already approved is
// left as it is, so re-running after a failure is safe.
//
//   node .github/scripts/testflight-external.mjs [--dry-run]
//
// Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY (PEM), ASC_APP_ID, BUILD_NUMBER,
//      MARKETING_VERSION, EXTERNAL_GROUP (default "External Testers"),
//      WHATS_NEW (optional "What to Test" text), WAIT_MINUTES (default 40).
//
// Exit codes: 0 when the build is in the group and submitted or approved, 1 otherwise.

import { createPrivateKey, createSign } from "node:crypto";
import { appendFileSync } from "node:fs";

const API = "https://api.appstoreconnect.apple.com";
const DRY_RUN = process.argv.includes("--dry-run");
const DEFAULT_WHATS_NEW = "Bug fixes and improvements.";

// External build states that need no further action from this script.
const SUBMITTED_STATES = new Set([
  "WAITING_FOR_BETA_REVIEW",
  "IN_BETA_REVIEW",
  "BETA_APPROVED",
  "IN_BETA_TESTING",
]);

function env(name, fallback) {
  const value = process.env[name] || fallback;
  if (!value) throw new Error(`${name} is not set`);
  return value;
}

// ES256 JWT; JWS needs the raw r||s signature, hence dsaEncoding "ieee-p1363".
function mintToken(keyId, issuerId, privateKey) {
  const b64 = (buf) =>
    Buffer.from(buf).toString("base64").replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "ES256", kid: keyId, typ: "JWT" };
  const payload = { iss: issuerId, iat: now, exp: now + 900, aud: "appstoreconnect-v1" };
  const input = `${b64(JSON.stringify(header))}.${b64(JSON.stringify(payload))}`;
  const signature = createSign("SHA256")
    .update(input)
    .sign({ key: createPrivateKey(privateKey), dsaEncoding: "ieee-p1363" });
  return `${input}.${b64(signature)}`;
}

function client({ keyId, issuerId, privateKey }) {
  // Tokens live 15 minutes and the processing wait can be longer, so mint per call.
  return async function asc(method, path, body) {
    const res = await fetch(`${API}${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${mintToken(keyId, issuerId, privateKey)}`,
        ...(body ? { "Content-Type": "application/json" } : {}),
      },
      ...(body ? { body: JSON.stringify(body) } : {}),
    });
    const text = await res.text();
    let json;
    try {
      json = text ? JSON.parse(text) : {};
    } catch {
      json = { raw: text };
    }
    return { ok: res.ok, status: res.status, json };
  };
}

function describe(res) {
  const errors = res.json?.errors;
  if (Array.isArray(errors) && errors.length) {
    return errors.map((e) => [e.code, e.title, e.detail].filter(Boolean).join(": ")).join(" | ");
  }
  return `HTTP ${res.status}`;
}

async function must(promise, what) {
  const res = await promise;
  if (!res.ok) throw new Error(`${what} failed (${describe(res)})`);
  return res;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** Polls until the uploaded build exists and has finished processing. Apple can take
 *  several minutes before an uploaded build appears in /v1/builds at all. */
async function waitForBuild(asc, appId, version, buildNumber, waitMinutes) {
  const deadline = Date.now() + waitMinutes * 60_000;
  const path =
    `/v1/builds?filter[app]=${appId}&filter[version]=${encodeURIComponent(buildNumber)}` +
    `&filter[preReleaseVersion.version]=${encodeURIComponent(version)}` +
    `&fields[builds]=version,processingState,usesNonExemptEncryption,expired&limit=1`;
  for (;;) {
    const res = await must(asc("GET", path), "looking up the build");
    const build = res.json.data?.[0];
    const state = build?.attributes?.processingState;
    if (state === "VALID") return build;
    if (state === "FAILED" || state === "INVALID") {
      throw new Error(`build ${version} (${buildNumber}) is ${state} in App Store Connect`);
    }
    if (Date.now() > deadline) {
      throw new Error(
        `build ${version} (${buildNumber}) was not processed within ${waitMinutes} minutes (state: ${state ?? "not found"})`,
      );
    }
    console.log(`Waiting for processing (state: ${state ?? "not visible yet"})...`);
    await sleep(30_000);
  }
}

/** Membership is read from the group side: /v1/builds/{id}/betaGroups only allows
 *  create and delete. */
async function groupHasBuild(asc, groupId, buildId) {
  let path = `/v1/betaGroups/${groupId}/builds?fields[builds]=version&limit=200`;
  while (path) {
    const res = await must(asc("GET", path), "reading the group's builds");
    if ((res.json.data ?? []).some((b) => b.id === buildId)) return true;
    const next = res.json.links?.next;
    path = next ? next.replace(API, "") : undefined;
  }
  return false;
}

async function externalState(asc, buildId) {
  const res = await must(asc("GET", `/v1/builds/${buildId}/buildBetaDetail`), "reading the beta state");
  return res.json.data?.attributes ?? {};
}

/** Sets "What to Test" on every beta localization of the build, creating one per app beta
 *  localization when the build has none. Text that is already set is kept unless a new
 *  note was given. */
async function setWhatsNew(asc, appId, buildId, note) {
  const existing = await must(
    asc("GET", `/v1/builds/${buildId}/betaBuildLocalizations?limit=50`),
    "reading What to Test",
  );
  const locs = existing.json.data ?? [];
  if (locs.length) {
    for (const loc of locs) {
      if (loc.attributes?.whatsNew && !note) continue;
      await must(
        asc("PATCH", `/v1/betaBuildLocalizations/${loc.id}`, {
          data: { type: "betaBuildLocalizations", id: loc.id, attributes: { whatsNew: note || DEFAULT_WHATS_NEW } },
        }),
        "updating What to Test",
      );
    }
    return;
  }
  const appLocs = await must(asc("GET", `/v1/apps/${appId}/betaAppLocalizations?limit=50`), "reading app locales");
  const locales = (appLocs.json.data ?? []).map((l) => l.attributes?.locale).filter(Boolean);
  for (const locale of locales.length ? locales : ["en-US"]) {
    await must(
      asc("POST", "/v1/betaBuildLocalizations", {
        data: {
          type: "betaBuildLocalizations",
          attributes: { locale, whatsNew: note || DEFAULT_WHATS_NEW },
          relationships: { build: { data: { type: "builds", id: buildId } } },
        },
      }),
      `adding What to Test for ${locale}`,
    );
  }
}

async function main() {
  const asc = client({
    keyId: env("ASC_KEY_ID"),
    issuerId: env("ASC_ISSUER_ID"),
    privateKey: env("ASC_PRIVATE_KEY"),
  });
  const appId = env("ASC_APP_ID");
  const buildNumber = env("BUILD_NUMBER");
  const version = env("MARKETING_VERSION");
  const groupName = env("EXTERNAL_GROUP", "External Testers");
  const note = (process.env.WHATS_NEW || "").trim();
  const waitMinutes = Number(process.env.WAIT_MINUTES || 40);

  // The app-scoped list does not accept filter[name]; groups are few, so match here.
  const groups = await must(asc("GET", `/v1/apps/${appId}/betaGroups?limit=200`), "listing beta groups");
  const group = (groups.json.data ?? []).find(
    (g) => g.attributes?.name === groupName && g.attributes?.isInternalGroup === false,
  );
  if (!group) throw new Error(`external beta group "${groupName}" not found on the app`);

  const build = await waitForBuild(asc, appId, version, buildNumber, waitMinutes);
  if (build.attributes?.usesNonExemptEncryption == null) {
    // Missing export compliance blocks external testing; Info.plist is expected to answer it.
    throw new Error("the build has no export compliance answer (ITSAppUsesNonExemptEncryption)");
  }

  const alreadyInGroup = await groupHasBuild(asc, group.id, build.id);
  let state = (await externalState(asc, build.id)).externalBuildState;

  if (DRY_RUN) {
    console.log(
      `Dry run: ${version} (${buildNumber}) is ${state}; ${alreadyInGroup ? "already in" : "would be added to"} "${groupName}".`,
    );
    return;
  }

  await setWhatsNew(asc, appId, build.id, note);

  if (!alreadyInGroup) {
    await must(
      asc("POST", `/v1/betaGroups/${group.id}/relationships/builds`, {
        data: [{ type: "builds", id: build.id }],
      }),
      `adding the build to "${groupName}"`,
    );
  }

  state = (await externalState(asc, build.id)).externalBuildState;
  if (!SUBMITTED_STATES.has(state)) {
    const submitted = await asc("POST", "/v1/betaAppReviewSubmissions", {
      data: {
        type: "betaAppReviewSubmissions",
        relationships: { build: { data: { type: "builds", id: build.id } } },
      },
    });
    // 409 means a submission already exists for this build.
    if (!submitted.ok && submitted.status !== 409) {
      throw new Error(`submitting for Beta App Review failed (${describe(submitted)})`);
    }
  }

  const final = await externalState(asc, build.id);
  const summary =
    `TestFlight external: ${version} (${buildNumber}) is in "${groupName}", ` +
    `state ${final.externalBuildState}. Testers are notified when Beta App Review approves it` +
    (final.autoNotifyEnabled ? "." : "; automatic notification is OFF for this build.");
  console.log(summary);
  if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${summary}\n`);
  if (!SUBMITTED_STATES.has(final.externalBuildState)) {
    throw new Error(`build is ${final.externalBuildState} after submission`);
  }
}

main().catch((err) => {
  console.log(`::error::${err instanceof Error ? err.message : String(err)}`);
  process.exit(1);
});
