---
name: meeting_briefing
description: "Prepare for meetings by gathering context, history, and open items into a structured brief. Use when the user wants to get ready for a meeting, understand what happened in past occurrences, catch up on a meeting they missed, know what to bring up, or review open items. Triggers on: prep me for, brief me for, what do I need to know, help me prepare, get me ready for, catch me up on, what's the context for, what was discussed, what should I bring up, what were the open items. Delivers a concise text brief — not a document or artifact."
---

# Meeting Briefing

**Execute Rounds 1–3 in strict sequential order. Do not skip any round, do not combine rounds, do not jump ahead. Each round produces output the next round depends on.**

### Round 1 — Identify the meeting

**Goal:** Find the specific meeting on the user's calendar, capture its full details, and classify it by type. The meeting type determines what context to pull in Round 2.
**Move on when:** You have the meeting details and its type classified.

Use `Meeting Lookup` to find the meeting. The user might reference it by:
- Time: "my 3pm", "my next meeting", "the call tomorrow morning"
- Name: "the QBR", "the design review", "sprint planning"
- Person: "my meeting with Vivek", "the customer call with Acme"

If ambiguous, search the user's upcoming calendar and ask to confirm which meeting.

Capture from the meeting event:
- Title, time, duration
- Full attendee list
- Description/agenda and any linked documents
- Whether it's recurring
- Whether there are external attendees (non-company email domains)

**Classify the meeting type:**

| Type | Signals | Brief focus |
|------|---------|-------------|
| **Customer/external** | Non-company email domains in attendees | Deal status, account history, open tickets, recent comms |
| **1:1** | Exactly 2 attendees | What changed since last 1:1, open action items, topics raised async |
| **Decision/review** | "review", "decision", "approval", "QBR", "planning" in title | Artifacts to review, pending decisions, stakeholder positions |
| **Recurring sync** | Recurring + multiple attendees + standup/sync/weekly | What's new since last occurrence, blockers, updates needed |
| **General** | None of the above | Attendee context, topic background, related docs |

### Round 2 — Gather context (parallel)

**Goal:** Pull all relevant context from multiple sources so the brief is comprehensive.
**Move on when:** You have context from all relevant sources.

**Run ALL of the following in parallel where possible:**

**(A) Attendee context — `Employee Search`**

**Call `Employee Search` once per attendee — ALL calls in parallel.** Collect name, title, team, location for each person.

**(B) Past meetings on the same topic — `Meeting Lookup`**

Search for past meetings by **topic/title** using the meeting's name or key topic words (`before:now`, look back 30-60 days). For recurring meetings, pull the **last 3-4 occurrences**. For 1:1s, search by participant name since the meeting title is the relationship. Set `extract_transcript:true` to pull transcripts.

From transcripts, extract:
- Key discussion points and decisions made
- Open action items and who owns them
- Unresolved questions or disagreements
- Any "let's follow up on X next time" commitments

**(C) Related documents and threads — `Glean Search`**

Run `Glean Search` queries using the meeting title and key attendee names to find:
- Related docs, design docs, PRDs, proposals
- Slack threads discussing the meeting topic
- Tickets or tasks related to the agenda
- Recent activity (updated in the last 2 weeks) relevant to the topic

For customer/external meetings, also search for:
- Account name + recent activity
- Open support tickets or escalations
- Recent email threads with the customer

Use `Glean Document Reader` on the most relevant results for deeper context.

**(D) Linked documents from the invite**

If the meeting description contains links (Google Docs, slides, Jira tickets), use `Glean Document Reader` to read them. These are the organizer's intended pre-reads — summarize their key points.

### Round 3 — Present the meeting brief

**Goal:** This round is the answer to the user's request. Everything before this was preparation. Now respond to the user with a structured, actionable brief.
**Move on when:** You have sent the brief to the user.

**This round is a text response, not a tool call. Write a message to the user.** Do not skip this round. Do not replace it with "Here's what I found."

**Adapt the brief format to the meeting type:**

**For customer/external meetings:**

> **Brief: [Meeting Title]**
> [Day, Date] · [Time] · [Duration]
>
> **Attendees**
> - [Name] ([Title], [Company]) — [role in this meeting if known]
> - ...
>
> **Account Context**
> [Deal stage, ARR, recent activity, renewal date, health signals]
>
> **Since Last Meeting**
> [Key changes: deal moved stages, new tickets filed, champion changed, recent comms]
>
> **Open Items**
> - [Action item from last meeting — status]
> - [Unresolved question — current state]
>
> **Talking Points**
> 1. [Suggested topic based on open items and recent activity]
> 2. [Topic from agenda if available]
> 3. [Risk or opportunity to raise]
>
> **Pre-reads**
> - [Doc title](link) — [one-line summary of what's relevant]

**For 1:1 meetings:**

> **Brief: 1:1 with [Name]**
> [Day, Date] · [Time]
>
> **What Changed Since Last 1:1**
> [Summary of what happened — projects, wins, blockers, escalations]
>
> **Open Action Items**
> - [Item from last 1:1 — status]
>
> **Topics to Discuss**
> [Topics raised in Slack/email since last 1:1, recent activity worth discussing]
>
> **Context**
> - [Relevant docs or threads](links)

**For decision/review meetings:**

> **Brief: [Meeting Title]**
> [Day, Date] · [Time] · [Duration]
>
> **Decision Needed**
> [What decision or approval is expected from this meeting]
>
> **Artifacts to Review**
> - [Doc/PRD/design](link) — [key points, what to pay attention to]
>
> **Stakeholder Positions** (if discoverable from threads/comments)
> - [Person A] favors [approach X] because...
> - [Person B] raised concerns about...
>
> **Open Questions**
> [Unresolved items that need answers in this meeting]

**For recurring syncs:**

> **Brief: [Meeting Title]**
> [Day, Date] · [Time]
>
> **Last Time**
> [Summary of what was discussed at the previous occurrence]
>
> **What's New**
> [Updates, changes, progress since last meeting]
>
> **Blockers / Needs Attention**
> [Items that are stuck or at risk]
>
> **Your Updates**
> [Prompt: "Here's what you've been working on that's relevant to this sync" — based on the user's recent activity]

**For general meetings:** Combine attendee context, topic background, and related docs into a clean brief.

**Keep the brief scannable.** Use bold headers, bullet points, and links. The user might be reading this 5 minutes before the meeting — every sentence should earn its place.
