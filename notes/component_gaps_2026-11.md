# Component gaps of the November KOT

Stage 8 review of the analysts' user stories against the component catalogue, 2026-11-08. Branch feature/5-nov, git-bug epic nov-kot, issue b0e896b.

## Decision (2026-11-08)

The technical part of the KOT does not change now: the component catalogue (7), component/technology (8), functions (13), information objects (10.1, 10.2) and matrix (11) stay as approved in the May KOT (kot_2026-05-27).

- **Court administration.** The OBP processes point to a possible new context of court administration (below). Existing services and components are to cover it.
- **Electronic signature, video conferencing, requests to agencies and external systems.** These are technical services, absorbed into the existing technical services of the System.
- **Reservation.** If the stakeholders request it, we redo this analysis, add new bounded contexts and change the technical solution section.

## How the gaps were found

Stage 8 (`rake review_components`, prompt `raw/prompts/review_components.txt`) gives the pipeline LLM each process description, the process's stories with their linked components, and the full component catalogue (`raw/data/components.jsonl`). Besides missing links, it reports a component gap when no component of the whole catalogue has a described function that covers what a story asks of the System. The prompt tells it not to report a gap when a component covers the need in general terms. Each gap names the unmet need, the closest component and why that component does not cover it.

The run covered all 231 processes without errors. It found 639 missing links, which `rake apply_review` adds to the component maps and stories, and 209 gaps in 85 processes. `rake check:component_gaps` joins the gaps with the story text in `out/check_component_gaps.jsonl`; the gap records themselves stay in `work/ba/{id}/{id}_components_review.jsonl`.

| Process family | Processes | With gaps | Gaps |
|---|---|---|---|
| KBP | 41 | 2 | 2 |
| TBP | 133 | 32 | 45 |
| OBP | 57 | 51 | 162 |
| Total | 231 | 85 | 209 |

The May review had no gap check, so there is no May figure to compare with. In May the pipeline LLM wrote the stories itself and wrote them around the existing components, so every story had a fitting component. The November stories are the analysts' own, taken verbatim, and some of them ask for functions that no component describes.

## Finding 1: court administration

51 of the 57 OBP processes have gaps, 162 in total. The catalogue is built around the court case: documents, deadlines, hearings, proceedings, insolvency. It has no component for running the court as an organisation, and the gap reasons say so story by story.

| Area | Processes | Gaps |
|---|---|---|
| Personnel: work books, personal files, service ID cards, leave schedules and leave, timesheets, staffing table, personnel reserve | OBP36, OBP38, OBP39, OBP45, OBP49, OBP50, OBP52, OBP58 | 30 |
| IT infrastructure and Service Desk: equipment maintenance, technical support of systems, IT supply, network monitoring, automated processes support, Service Desk requests | OBP14, OBP17, OBP19, OBP23, OBP33, OBP34 | 28 |
| Procurement, contracts and supplies: orders, contract execution control, inventory, receiving, issuing and writing off goods | OBP18, OBP29, OBP30, OBP53, OBP54, OBP55, OBP56 | 24 |
| Accounting, budget and taxes: budget requests, budget reporting, accounting, tax payments, settlements with suppliers, the court's deposit account | OBP40, OBP41, OBP42, OBP43, OBP44, OBP57 | 19 |
| Library and legal reference: codification work, buying printed editions, legislation updates, issuing literature, legal reference systems | OBP12, OBP13, OBP16, OBP20, OBP21 | 17 |
| Buildings and safety: sanitation, fire safety, staff briefings, building operation, labour safety | OBP24, OBP25, OBP26, OBP27, OBP28 | 12 |
| Media and the court website | OBP31, OBP32, OBP35 | 10 |
| Internal orders and document registers | OBP37, OBP46, OBP47, OBP48 | 8 |
| Archive, citizens' requests, internal events | OBP6, OBP9, OBP10, OBP15 | 8 |
| Reports and statistics | OBP1, OBP3, OBP4 | 6 |

Examples of the needs, in the pipeline LLM's words (full text in `out/check_component_gaps.jsonl`):

- OBP19-US-04: start a procurement under 44-ФЗ and keep the contract basis of a supply. Closest К-СДМ, which only routes messages.
- OBP20-US-01: keep the court's stock of printed editions and track each copy to its holder. Closest К-МД; К-УВД tracks material objects only as evidence in cases.
- OBP23-US-01, OBP23-US-02: monitor the court's network channels and register staff requests about outages. Closest К-ПИ, which only sends notifications.
- OBP24-US-02: record checks of a state contract's execution and build claims against the contractor. Closest К-ОА.
- OBP42-US-10: close the financial year. Closest К-ОА.
- OBP43-US-04, OBP43-US-07, OBP43-US-09, OBP43-US-10: compute the court's taxes as an employer, prepare payment orders, post to the accounting registers, prepare 6-НДФЛ and ЕФС-1. Closest К-ФЭК, К-УФД, К-ФДС, К-СС, all of which work on court cases.
- OBP44-US-02: record budget obligations under contracts against limits and expense items. Closest К-УФД.

The components the pipeline LLM named closest are the ones existing services would build on: К-МД (51 gaps across all families), К-ВДД (19), К-ИПП (13), К-УДП (11), К-УФД (10), К-СДМ (10), К-ОА (9), К-ПЗ (9), К-ПИ (8), К-УНСИ (7).

If the stakeholders ask for this to be modelled, the areas of the table are the candidates to examine as one or more bounded contexts of court administration.

## Finding 2: technical services

Three needs recur across the core processes and also appear in the OBP gaps. No component description names them.

**Electronic signature, seal and stamp (14 core gaps).** Signing a document with УКЭП, applying the court's electronic seal to signed documents and certified copies, verifying a signature, the electronic registration stamp. Only К-ПСЗ signs, and only the hearing protocol; К-УДП and К-СИД authenticate and authorise. Stories: TBP31-US-21, TBP31-US-23, TBP49-US-05, TBP49-US-07, TBP49-US-15, TBP50-US-03, TBP80-US-05, TBP85-US-06, TBP86-US-04, TBP88-US-01, TBP9-US-02, TBP9-US-06, TBP8-US-01, TBP55-US-08. The same need appears in OBP stories, for example OBP20-US-03, OBP20-US-05, OBP42-US-08, OBP44-US-04.

**Video and web conferencing (9 core gaps).** Setting up and running a ВКС or web-conference session, agreeing it with the assisting court, recording it, online interviews with the parties. Closest К-ПЗ (calendars and rooms), К-СП, К-ПСЗ, К-СУП. Stories: TBP136-US-02, TBP136-US-04, TBP44-US-03, TBP44-US-05, TBP51-US-02, TBP51-US-03, TBP66-US-05, TBP67-US-01, TBP68-US-02.

**Requests to agencies and external systems (14 core gaps).** Closest К-СУП for the four ТБП23 requests (it manages court orders to external parties such as banks), К-ИП, К-ЭИЗ, К-ЕФРСБ, К-ИПП, and for TBP21 К-СДМ, К-ПИ, К-ВДД, К-АЖС. The catalogue has dedicated gateways only for ЕФРСБ (К-ЕФРСБ) and ЕГРЮЛ with registrars (К-ИРК).

- Requests to an agency under ТБП23: TBP100-US-02, TBP108-US-04, TBP58-US-03, TBP77-US-04.
- The register of natural monopolies of ФАС: TBP105-US-01.
- ФССП: TBP22-US-02, TBP90-US-01.
- Hybrid mail statuses of Почта России: TBP3-US-03.
- КАД Арбитр and ЕПЦП: TBP57-US-02.
- TBP21 «Направить автоматический запрос в другую ИС», all five stories: the request card and its answer, errors, the support ticket, the recorded cause, recommendations (TBP21-US-01 to TBP21-US-05).

## Other gaps

Ten single needs in core processes, recorded under the same decision:

- KBP84-US-17: return a case from the archive to the working circuit (closest К-АД).
- KBP86-US-04: random choice of an СРО with a reproducible record (closest К-АУ-Н).
- TBP1-US-07: delivery status across all notice channels (closest К-ЭИЗ).
- TBP11-US-11: a tracked task for the judge to read the chairman's ruling (closest К-ВДД).
- TBP43-US-03: the ТБП139 check of the System's conclusions (closest К-МД).
- TBP48-US-05: replacing a recused specialist, interpreter, assistant or assessor (closest К-УСС).
- TBP55-US-02: checking whether the same case is already registered (closest К-ПСР).
- TBP55-US-09: finding the lower-court case of an appeal or cassation complaint (closest К-АП).
- TBP79-US-02: checking a candidate expert for conflicts of interest (closest К-СЭ).
- TBP82-US-07: imposing a court fine on the head of an expert organisation (closest К-СП).

## Components without stories

After `apply_review`, four catalogue components have no story: К-ДЗ-О, К-КИ and К-ГИ (none in May either) and К-ГСА (4 stories in May). They stay in the frozen catalogue.

## Redoing the analysis

The gap records stay in the review files, and `rake check:component_gaps` rebuilds the report from them without the LLM. Any edit to `raw/data/components.jsonl` makes stage 4 rebuild for all 231 processes, because the catalogue is a prerequisite of its rule, and stages 5 and 8 follow. A future change to the catalogue should therefore be prepared so that only the affected processes run again.
