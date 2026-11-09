# Information object gaps of the November KOT

Stage 6b check of the analysts' user stories against the frozen information objects of their components, 2026-11-09. Branch feature/5-nov, git-bug epic nov-kot, issue ea5a476. Companion to `notes/component_gaps_2026-11.md`.

## Decision (2026-11-10)

The information objects stay as approved in the May KOT (kot_2026-05-27): the objects (10.1), the reference views (10.2) and matrix component/information object (11) do not change, in line with decision 5 of the epic. Stage 6 is frozen (`REBUILD_PROJECTIONS=1` is the only way to regenerate it).

- **Court administration.** The OBP gaps fall under the decision of 2026-11-08: existing services and components cover court administration, and so do their objects.
- **Technical services.** Requests to agencies and external systems, video conferencing and electronic signature are absorbed into the existing technical services.
- **Results of checks and reference lists.** Covered in general terms by the existing check protocols and by the generic reference catalogue.
- **Case data and other single needs.** Recorded here as the candidates for a future redo.
- **Reservation.** If the stakeholders request it, we redo this analysis and change the information objects together with the technical solution section.

## How the gaps were found

Stage 6b (`rake info_gaps`, prompt `raw/prompts/info_gaps.txt`) gives the pipeline LLM, per component, its catalogue description, its information objects with their KOT codes (`{cid}-AG-01` for the aggregate of table 10.1, the projection codes of table 10.2), the catalogue descriptions of the other components linked to its stories, and the linked stories of the 231 active processes. It reports a gap when none of the component's objects represents information that a story needs from this component. The prompt tells it not to report a gap when an object covers the information in general terms, nor information that belongs to another linked component. Each gap names the need, the closest object of the component and why that object does not represent it. Components with more than 150 stories were checked in even batches.

The check sees a component's own objects only. The other linked components appear with their catalogue description, not with their objects, so a gap can name information that an object of another component already holds (see family 5).

The run covered all 76 components without errors: 2028 stories with 3783 story-component links, in the 72 components that have stories. It found 303 gaps for 291 stories in 126 processes and 51 components; 21 components with stories have none. `rake check:info_gaps` joins the gaps with the story text in `out/check_info_gaps.jsonl`; the gap records stay in `work/ta/{cid}/{cid}_info_gaps.jsonl`.

| Process family | Processes with gaps | Stories with gaps | Gaps |
|---|---|---|---|
| KBP | 15 | 30 | 32 |
| TBP | 67 | 127 | 132 |
| OBP | 44 | 134 | 139 |
| Total | 126 | 291 | 303 |

The May KOT had no such check. In May the pipeline LLM wrote the stories and then derived the projections from them, so the objects fitted the stories. The November stories are the analysts' own, taken verbatim.

| # | Family | Gaps | Stories | Disposition |
|---|---|---|---|---|
| 1 | Court administration (OBP stories) | 139 | 134 | Decision of 2026-11-08 |
| 2 | Technical services | 24 | 23 | Absorbed into the technical services |
| 3 | Results of checks and the System's conclusions | 48 | 47 | Covered in general terms |
| 4 | Reference lists and templates | 12 | 12 | Covered in general terms |
| 5 | Case data in К-СП | 29 | 29 | Candidate for a redo |
| 6 | Other single needs in legal components | 51 | 48 | Candidate for a redo |

A story can fall in two families when two of its components report it, so the story column adds up to more than 291.

## Family 1: court administration

139 gaps in 44 OBP processes. They repeat finding 1 of the component gaps: the components and their objects are built around the court case, and the OBP stories need information about running the court as an organisation.

| Closest component | Gaps | Processes | Information the stories need |
|---|---|---|---|
| К-ИПП | 22 | OBP9, OBP10, OBP12, OBP16, OBP23, OBP29, OBP31, OBP35, OBP46 | The System's analysis and drafts outside court cases: routing of citizens' requests, analysis of legislation changes and drafts of local acts, failure diagnostics, contract breach conclusions, classification of media requests, news drafts, storage periods |
| К-УНСИ | 17 | OBP14, OBP24, OBP32, OBP42, OBP43, OBP50, OBP53, OBP55, OBP56 | Administrative reference data: equipment, sanitary norms, media sources and keywords, the goods classifier and issue norms, payroll accrual types and salaries, taxes and rates, absence types and the production calendar, write-off reasons |
| К-ОА | 15 | OBP24, OBP32, OBP33, OBP40, OBP42, OBP43, OBP44 | Administrative reports: contract and sanitation control, media monitoring reviews, the Service Desk queue, costs against results, the annual financial report, taxes, contract settlements |
| К-СДМ | 13 | OBP17, OBP33, OBP35, OBP43, OBP44 | Equipment failures and requests to contractors, news materials and their approval, tax calculation and the Treasury confirmation, remarks of ФНС and СФР, payment requests |
| К-МД | 12 | OBP15, OBP17, OBP25, OBP36, OBP39, OBP54 | Event programmes and equipment, maintenance history, fire drills, work books and service ID cards issued, warehouse stock |
| К-ВДД | 9 | OBP13, OBP15, OBP37, OBP49 | Approval visas and remarks on local acts and on the list of printed editions, staff assigned to events, the holiday pay check |
| К-УДП | 7 | OBP13, OBP19, OBP34, OBP55 | Judges' requests for printed editions, computer equipment supply and acceptance, IT staff workload, the goods issue log |
| К-ПИ | 7 | OBP9, OBP34, OBP45 | Service Desk tickets and the equipment issue log, leave wishes, the status of a citizen's request |
| 13 other components | 37 | | К-ПСР 6, К-АД 5, К-ПЗ 4, К-РИО 4, К-ПА 4, К-СС 4, К-УФД 3, К-САС 2, К-ПД, К-СИД, К-СП, К-КТ, К-ФДС 1 each |

## Family 2: technical services

24 gaps in 6 processes, the same services as finding 2 of the component gaps.

- **Requests to agencies and external systems (19).** ТБП23 «Запрос в ведомство», 17 gaps: in К-СП the request, its fields, the answer and its link to the request, the control date, repeat and clarifying requests, the report and the grounds for a court fine (TBP23-US-01, TBP23-US-08, TBP23-US-12, TBP23-US-15, TBP23-US-18, TBP23-US-20, TBP23-US-21, TBP23-US-24, TBP23-US-26, TBP23-US-27, TBP23-US-28, TBP23-US-30); in К-УНСИ the directory of agencies, their official sites and competence (TBP23-US-02, TBP23-US-03, TBP23-US-07); TBP23-US-04 (К-СДМ) and TBP23-US-23 (К-ПСР). Also TBP21-US-01, the answer of an automatic request to another system (К-СДМ), and TBP58-US-01, the representative's data from official sources (К-ИРК).
- **Video conferencing (4).** Attendance at a ВКС hearing and the incoming order of the assisting court: TBP136-US-01 (К-СП), TBP136-US-03 (К-СП and К-СУП); the recommended and approved assisting court: TBP51-US-02 (К-ПЗ).
- **Electronic signature (1).** The reason of a failed check of the judge's УКЭП on a court act: TBP8-US-07 (К-СП).

## Family 3: results of checks and the System's conclusions

48 gaps. The need is the recorded result of one particular check or conclusion. The check protocols of К-ПСР (PR-01 «Результаты проверки заявления» to PR-08) and К-ИПП-PR-02 «Протокол автоматических проверок» represent such results in general terms; the pipeline LLM reported them because the particular check is not named.

- **Formal and admissibility checks in К-ПСР (19).** Readability, format and size of files (TBP7-US-03, TBP53-US-01, TBP53-US-07, TBP141-US-01, TBP141-US-04), the physical state of a paper document (TBP53-US-03), required fields of a draft (TBP49-US-12), the case card (TBP55-US-06), the parties, the prosecutor, succession and joinder (TBP115-US-03, TBP116-US-03, TBP116-US-04, TBP116-US-23, TBP116-US-24, TBP116-US-40), the right to apply for subsidiary liability (KBP41-US-01, KBP41-US-06), transaction parameters (TBP98-US-01), grounds for termination (TBP142-US-06), signs of a forged payment document (TBP26-US-04).
- **Confidentiality of deliberations in К-СП (7).** TBP127-US-01, TBP129-US-01, TBP131-US-01, TBP132-US-01, TBP133-US-01, TBP134-US-01, TBP140-US-01.
- **Other results and conclusions (22).** Jurisdiction (TBP19-US-06) and proper notice (TBP4-US-05) in К-СП; debtor categories in К-ПДБ-О and К-ПДБ (TBP100-US-04, TBP101-US-03, TBP104-US-03 twice, TBP105-US-03); grounds for transfer in К-ОП (TBP65-US-04, TBP65-US-05, TBP65-US-06); the state fee in К-УФД (TBP37-US-07, TBP41-US-03); financial calculations in К-ФЭК (TBP59-US-04, TBP59-US-06); the procedure determined by the System in К-ПК (TBP80-US-01) and К-КП (KBP92-US-04); grounds for review in К-ПСН (TBP71-US-04); completeness of enforcement data in К-ИП (TBP22-US-03); a foreign party's representative in К-МПП (TBP124-US-01); a case not subject to archiving in К-АД (TBP89-US-02); error reports and the ТБП139 control check in К-ИПП (TBP139-US-02) and К-МД (TBP43-US-03).

## Family 4: reference lists and templates

12 gaps. К-УНСИ-AG-01 «Справочник» is a generic catalogue (CatalogId, ItemsList, Version, ActivationDate) that holds any list, and the named classifiers of 10.2 are instances of it.

- К-УНСИ (8): documents required for an application (KBP14-US-15, KBP15-US-44), fine limits by category of subject (TBP16-US-01), procedural actions (TBP31-US-15), grounds for leaving a claim without consideration (TBP36-US-03) and for termination (TBP64-US-03), КоАП penalties (TBP93-US-03, TBP93-US-05).
- К-ПД (3): templates of applications to challenge a debtor's transaction (KBP72-US-01, KBP72-US-06); kinds of procedural documents and file formats (TBP7-US-01), held by К-УНСИ-PR-03 «Классификатор видов документов».
- К-СС (1): the forms of statistical reports (TBP2-US-01), held by К-ОА-PR-01 «Каталог доступных отчетов» and К-ОА-PR-09 «Форма статистической отчетности».

## Family 5: case data in К-СП

29 gaps. The May aggregate К-СП-AG-01 «Дело» holds the case ID, status, judge, parties, hearing schedule and key documents. The November stories ask К-СП for more of the case.

| Information | Stories | Objects of other components |
|---|---|---|
| Attendance at a hearing, the absent parties and the reasons | TBP1-US-03, TBP1-US-04, TBP1-US-05, TBP1-US-08, TBP1-US-09, TBP1-US-10, TBP1-US-11, TBP1-US-13, TBP16-US-03 | К-ПЗ-PR-05 «Сводка явки участников», К-ПЗ-PR-03 «Карточка судебного заседания», К-ПСЗ-PR-05 «Справка о явке участников». TBP1-US-08, TBP1-US-09, TBP1-US-10 and TBP16-US-03 link К-ПЗ; the others link neither К-ПЗ nor К-ПСЗ |
| The claims of the case, amounts of debt and sanctions, the set-off result | TBP68-US-05, TBP68-US-22, TBP76-US-01, TBP76-US-04, TBP122-US-03, TBP140-US-09 | Not checked across the registry |
| Established and unestablished circumstances, reasons for rejecting evidence | TBP59-US-12, TBP59-US-13, TBP59-US-14 | К-ИПП-PR-04 «Анализ доказательств и фактов» analyses the established facts; the stories link К-СП only |
| Grounds for suspending or postponing proceedings | TBP63-US-23, TBP73-US-01 | Suspension appears in objects of other components; a keyword search found no object on postponement |
| Other: the order of distributing property and the manager's report (KBP13-US-12, KBP13-US-22), results of preparing a case (KBP15-US-46), incoming foreign requests (KBP90-US-07), the category of dispute (TBP142-US-04), the status of requests for evidence (TBP18-US-01), answers to a private ruling (TBP24-US-01, TBP24-US-02), the link of a separated case to the main case (TBP61-US-05, also in К-УПД) | 9 stories | Not checked across the registry |

## Family 6: other single needs in legal components

51 gaps for 48 stories: specific details missing from objects that are otherwise relevant.

| Component | Stories and needs |
|---|---|
| К-ПД (6) | KBP4-US-14 blocking filing after a missed deadline and lifting it; KBP85-US-02, KBP85-US-03 a draft bankruptcy petition kept before sending and its withdrawal; KBP85-US-04 restrictions on filing such as a moratorium; KBP91-US-02 the kind of violated right in a compensation claim; KBP88-US-04 the paper or electronic form of an incoming document and its scanning |
| К-МД (5) | TBP46-US-09 delivery data per sent document; TBP46-US-12 outgoing number and date; TBP49-US-14 the judge's remarks on a returned draft; TBP55-US-10 a document's link to a separate dispute; TBP62-US-03 date, time and place for reading the case file |
| К-ВДД (4) | KBP15-US-50 receipt of each document rather than the package; TBP106-US-01, TBP106-US-02, TBP106-US-03 the reason for an internal transfer and for refusing it |
| К-МПП (3) | KBP90-US-03, KBP90-US-05 incoming requests of foreign courts and bodies; TBP69-US-05 the signed protocol handed to the interpreter |
| К-ОС-С (3) | KBP39-US-10 documentary or general procedure of a separate dispute; KBP40-US-03 the contested transaction for the ЕФРСБ publication; TBP119-US-03 the result of preparing the dispute |
| К-ВП (2) | TBP31-US-04 the status «Отказано в принятии»; TBP31-US-20 general or simplified procedure as a mark |
| К-ИПП (2) | TBP139-US-03 data the judge enters in place of the System's; TBP46-US-07 the transcript of a telephone message |
| К-УПД (2) | KBP91-US-17 the result synchronised with the original case; TBP61-US-05 the link of a separated case to the main case |
| К-ПВ (2) | KBP86-US-24, KBP86-US-25 changes to a debt restructuring plan |
| К-ПДА (2) | TBP107-US-02, TBP107-US-03 the remedy and its deadline, the duty to report execution |
| К-ПДБ-ФЛ (2) | KBP72-US-01 the debtor's transactions subject to challenge; KBP86-US-30 restrictions on the citizen after the procedure |
| К-ПП (2) | KBP57-US-15 the cassation result shown in the order case; TBP91-US-03 voluntary payment by the debtor |
| К-ПСН, К-ПВО (1 each) | TBP71-US-01 the grounds for review chosen by the judge |
| Single gaps | К-АП TBP55-US-09 appeal data as sent by the lower court; К-АУ-Н KBP86-US-17 opinions on the candidate manager; К-КС TBP127-US-02 the contested transaction in a corporate claim; К-ОА and К-УПС TBP5-US-07 compliance with deadlines and the reasons for missing them; К-ПСЗ TBP69-US-02 the hearing video record; К-ПСР KBP85-US-04 restrictions on filing; К-РТК KBP85-US-26 whether the register of claims is open and until when; К-СР TBP72-US-02 the parties' agreement on costs; К-СУП TBP121-US-03 deadline and manner of producing requested evidence; К-СЭ TBP77-US-05 the specialist and the consultation; К-УП KBP39-US-14 an application to correct typos; К-УС TBP68-US-09 an offer to settle and the replies; К-УСС TBP108-US-04 the judge's possible interest |

## Components without gaps or stories

21 components with stories have no gap. К-ДЗ-О, К-КИ, К-ГСА and К-ГИ have no story and got an empty file without an LLM call.

## Redoing the analysis

- `rake check:info_gaps` rebuilds the report from the gap files without the LLM.
- Before any change to the objects, check every gap of families 5 and 6 against the objects of all components. Some of the information is already held by another component (attendance, the analysis of facts), which makes the gap a missing story-component link rather than a missing object.
- Stage 6b reruns for every component when a story file, an aggregate, the prompt or the catalogue changes.
- Projections regenerate only with `REBUILD_PROJECTIONS=1`, and then for every component whose aggregates or prompt are newer. A redo should change only the affected components, and matrix 11 follows from tables 10.1 and 10.2.
