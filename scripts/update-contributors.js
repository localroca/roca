#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const startMarker = "<!-- contributors:start -->";
const endMarker = "<!-- contributors:end -->";
const maxContributors = Number.parseInt(process.env.CONTRIBUTORS_MAX ?? "36", 10);
const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const readmePath = path.resolve(scriptDirectory, "..", "README.md");

function repositorySlug() {
    if (process.env.GITHUB_REPOSITORY) {
        return process.env.GITHUB_REPOSITORY;
    }

    try {
        const remote = execFileSync("git", ["config", "--get", "remote.origin.url"], {
            encoding: "utf8"
        }).trim();
        const match = remote.match(/github\.com[:/]([^/]+)\/([^/.]+)(?:\.git)?$/);
        if (match) {
            return `${match[1]}/${match[2]}`;
        }
    } catch {
        // Fall through to the public repository default.
    }

    return "localroca/roca";
}

function escapeHTML(value) {
    return value
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll('"', "&quot;");
}

async function fetchContributors(owner, repo) {
    const token = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
    const headers = {
        Accept: "application/vnd.github+json",
        "User-Agent": "roca-contributors-generator",
        "X-GitHub-Api-Version": "2022-11-28"
    };
    if (token) {
        headers.Authorization = `Bearer ${token}`;
    }

    const url = new URL(`https://api.github.com/repos/${owner}/${repo}/contributors`);
    url.searchParams.set("anon", "false");
    url.searchParams.set("per_page", String(Math.max(1, Math.min(maxContributors, 100))));

    const response = await fetch(url, { headers });
    if (!response.ok) {
        throw new Error(`GitHub contributors request failed: ${response.status} ${response.statusText}`);
    }
    const contributors = await response.json();
    return contributors
        .filter((contributor) => contributor.type !== "Bot" && !contributor.login.endsWith("[bot]"))
        .slice(0, maxContributors);
}

function renderContributors(contributors) {
    if (contributors.length === 0) {
        return "No contributors found yet.";
    }

    const avatars = contributors
        .map((contributor) => {
            const login = escapeHTML(contributor.login);
            const profileURL = escapeHTML(contributor.html_url);
            const avatarURL = escapeHTML(`${contributor.avatar_url}&s=80`);
            return `<a href="${profileURL}" title="@${login}"><img src="${avatarURL}" width="40" height="40" alt="@${login}" /></a>`;
        })
        .join("\n");

    return `${avatars}\n\n<sub>Updated automatically from GitHub contributor data.</sub>`;
}

async function main() {
    const [owner, repo] = repositorySlug().split("/");
    if (!owner || !repo) {
        throw new Error("Could not determine GitHub repository slug.");
    }

    const readme = await readFile(readmePath, "utf8");
    const start = readme.indexOf(startMarker);
    const end = readme.indexOf(endMarker);
    if (start === -1 || end === -1 || end < start) {
        throw new Error("README.md is missing contributor markers.");
    }

    const contributors = await fetchContributors(owner, repo);
    const generated = renderContributors(contributors);
    const updated = `${readme.slice(0, start + startMarker.length)}\n${generated}\n${readme.slice(end)}`;

    if (updated !== readme) {
        await writeFile(readmePath, updated);
    }
}

await main();
