# JOB ENGINE — `core/jobs.uc`

Движок задач Tachyon: единая точка для всего, что выполняется дольше одного
тика watchdog, должно быть отменяемым и наблюдаемым. Файл — 1100 строк,
экспортируется через `module_exports()`.

Документ описывает фактический код. Если расходишься с кодом — правь код.

---

## 1. Зачем

До движка задач фоновая работа описывалась ad hoc: `command_status(... "&")`,
`log_message()` в потоке, состояние в `/tmp` без идентификатора. Отсюда
три класса проблем:

- **неотменяемость** — операция на 5 минут не знала, что пользователь нажал «отмена»;
- **неразличимость** — нельзя было сказать, идёт ли апдейт или завис;
- **нет отката** — упавшая на середине запись UCI оставляла систему в промежуточном состоянии без внятной границы.

`core/jobs.uc` даёт задаче идентичность, фазу, журнал, heartbeat, кооперативную
отмену и стек компенсаций.

---

## 2. Фазы жизненного цикла

```ucode
const PHASE_CREATED     = "created";
const PHASE_QUEUED      = "queued";
const PHASE_PREFLIGHT   = "preflight";
const PHASE_RUNNING     = "running";
const PHASE_VERIFYING   = "verifying";
const PHASE_COMMITTING  = "committing";
const PHASE_ROLLBACK    = "rollback";
const PHASE_SUCCESS     = "success";
const PHASE_FAILED      = "failed";
const PHASE_CANCELLED   = "cancelled";
```

Нормальный путь:

```
created → queued → preflight → running → verifying → committing → success
```

Пути отказа:

```
preflight   провален              → failed
running     провален              → rollback → failed
committing  провален              → rollback → failed
running     запрошена отмена      → rollback → cancelled
```

Терминальные фазы — `success`, `failed`, `cancelled`. `gc()` собирает мусор по
ним; всё остальное считается активным (`list_active()`).

`transition(job, phase)` — единственная точка смены фазы. Она пишет state-файл,
а не только память: воркер может быть убит в любой момент, и следующий читатель
(`/usr/bin/tachyon job_query`, watchdog, UI) обязан увидеть актуальное.

---

## 3. Идентичность и защита от PID recycling

Задача — это процесс. Процесс — это PID, а PID переиспользуется. Движок не
полагается на голый PID: идентичность задаётся тройкой из `core/process.uc`:

- `pid`
- `starttime` (поле 22 в `/proc/<pid>/stat`)
- `boot_id`

`is_stale(job)` = «процесса с таким PID уже нет» **или** «PID жив, но это
другой процесс». Второе и есть ловушка: без `starttime` задача, упавшая
вчера, выглядит живой сегодня, если система дала тот же PID.

---

## 4. Файлы задачи

| Что | Где | Зачем |
|---|---|---|
| Состояние | `<state_dir>/<job_id>.json` | единственный источник правды |
| Журнал | `<state_dir>/<job_id>.log` | хвост работы, показывается в UI и в CLI |
| Heartbeat | поле в state-файле | отсечка зависших задач |

Пути вычисляются из `TACHYON_JOB_STATE_FILE` / `TACHYON_JOB_LOG`, которые
пробрасываются в окружение воркера — воркер не обязан знать layout каталога.

Запись состояния **атомарна** (tmp + `mv`): состояние читается конкурентно из
UI и watchdog, и оборванная запись JSON сделала бы задачу нечитаемой.

---

## 5. Heartbeat и потолок времени

`heartbeat(job)` обновляет отметку; `TACHYON_JOB_HEARTBEAT_INTERVAL` и
`TACHYON_JOB_HARD_DEADLINE_SECONDS` ограничивают воркер сверху.

Разделение намеренное:

- **heartbeat** ловит «воркер жив, но застрял» (нет прогресса);
- **hard deadline** ловит «воркер мёртв или завис намертво».

Одного heartbeat мало: код может быть жив и при этом бесконечно зациклен.

---

## 6. Кооперативная отмена

Отмена не убивает процесс — она просит его остановиться в безопасной точке.

```
request_cancel(job, reason)     → пишет флаг в state-файл, шлёт факт в шину
is_cancel_requested(job)        → читает актуальный state (важно для кросс-процессности)
check_cancellation(job)         → точка проверки внутри воркера
```

`request_cancel` **не** полагается на память вызывающего: запрос может прийти
из другого процесса (UI, Telegram, CLI), поэтому флаг пишется на диск, и
`is_cancel_requested` перечитывает файл.

### Критические секции

Прямо посреди неделимой операции — записи прошивки, транзакции UCI — отмена
создала бы промежуточное состояние. Поэтому:

```
enter_critical_section(job, name)  → in_critical_section = true
leave_critical_section(job)        → если отмена была — обработать СЕЙЧАС
with_critical_section(job, name, fn) → гарантированный выход
```

Внутри критической секции `check_cancellation()` возвращает `deferred: true` и
не трогает фазу. Отмена «переносится» и срабатывает на `leave_critical_section`
— в тот момент, когда система снова в согласованном состоянии.

---

## 7. Стек компенсаций (откат)

```
register_rollback(job, spec)   → кладёт компенсацию в LIFO-стек
execute_rollback(job)          → выполняет в обратном порядке
```

Обратный порядок обязателен: если сначала изменили `A`, потом `B`, то откат
должен сначала вернуть `B`, иначе откат `A` может инвалидировать состояние,
которое ещё не откачено.

Спецификация компенсации может быть функцией, shell-командой или срезом файла.
`rolled_back` и `rollback_error` пишутся в state — по итогу отката всегда
видно, откатилось ли.

`run_steps(job, steps)` — конвейер: массив шагов `{name, run, rollback}`,
перед каждым шагом проверяется отмена, выполненные регистрируют компенсации,
после отмены оставшиеся шаги не выполняются.

`cancel_force(job)` — принудительный путь: `exec.kill_identity()` (SIGTERM с
эскалацией до SIGKILL), `cancel_forced = true`. Нужен, когда воркер не
кооперирует (завис в системном вызове).

---

## 8. Клиенты

| Клиент | Методы |
|---|---|
| `jobs.uc` (CLI) | `create`, `queue`, `preflight`, `transition`, `start_shell`, `heartbeat`, `complete`, `query`, `list_active`, `list_all`, `gc`, `run_job` |
| `core/events.uc` | факты отмены в шину |
| `jobClient.ts` | `list`, `query`, `cancel`, `requestCancel`, `gc`, `watch` + предикаты `isJobActive`, `isJobTerminal`, `isJobSuccessful` |

CLI: `tachyon job_list [--all] [--json]`, `job_query <id>`,
`job_request_cancel <id> [reason]`, `job_cancel <id> [--force] [reason]`, `job_gc`.

`jobClient.watch()` — не реактивность, а опрос с колбэком прогресса,
таймаутом и поддержкой `AbortSignal`. На OpenWrt нет дешёвого способа
подписаться на поток задач, а поллить `query` по таймеру — предсказуемо.

---

## 9. Тесты

`tests/job_cancellation.sh` — 7 групп: экспорт API, полный цикл отмены,
критическая секция с отложенной отменой, `with_critical_section`, строгий LIFO
порядок компенсаций, многошаговый конвейер, CLI-диспетчеризация.

`tests/jobs_module.sh` — базовый жизненный цикл.

---

## 10. Связанные документы

- `TRANSACTION_ENGINE.md` — транзакции, которые задачи используют как компенсации
- `EVENTS.md` — факты, которые движок публикует
- `STATE_MODEL.md` — где лежит state-файл задачи среди прочих состояний
