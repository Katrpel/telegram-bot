import asyncio
import logging
import csv
import io
from datetime import datetime, timedelta
from aiogram import Bot, Dispatcher, F
from aiogram.filters import Command
from aiogram.types import (
    Message, InlineKeyboardMarkup, InlineKeyboardButton,
    CallbackQuery, BufferedInputFile, ReplyKeyboardMarkup,
    KeyboardButton
)
from sqlalchemy import (
    create_engine, Column, Integer, String, DateTime,
    BigInteger, ForeignKey, select, func
)
from sqlalchemy.orm import DeclarativeBase, Session, relationship

BOT_TOKEN = "8365458785:AAHyVIla42H9kRKG0oT8SQvjiOFiWjOeTSE"
ADMIN_IDS = [1170348114, 358930137]
PAGE_SIZE = 10
MAX_ATTACHMENTS = 20

logging.basicConfig(level=logging.INFO)

CATEGORIES = {
    "raw": " Исходное сырьё",
    "analysis": " Анализ",
    "mech": " Механоактивация",
    "forming": " Формование",
}

DATE_FILTERS = {
    "today":  "📅 Сегодня",
    "yday":   "📅 Вчера",
    "7d":     "📅 За 7 дней",
    "30d":    "📅 За 30 дней",
    "all":    "📅 Всё время",
}

class Base(DeclarativeBase):
    pass

class User(Base):
    __tablename__ = "users"
    user_id = Column(BigInteger, primary_key=True)
    full_name = Column(String, nullable=False)
    registered_at = Column(DateTime, default=datetime.now)

class Note(Base):
    __tablename__ = "notes"
    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(BigInteger, index=True)
    author_name = Column(String)
    category = Column(String, index=True)
    text = Column(String, nullable=True)
    photo_id = Column(String, nullable=True)
    document_id = Column(String, nullable=True)
    document_name = Column(String, nullable=True)
    created_at = Column(DateTime, default=datetime.now)
    updated_at = Column(DateTime, nullable=True)
    attachments = relationship("Attachment", back_populates="note",
                               cascade="all, delete-orphan", order_by="Attachment.id")

class Attachment(Base):
    __tablename__ = "attachments"
    id = Column(Integer, primary_key=True, autoincrement=True)
    note_id = Column(Integer, ForeignKey("notes.id", ondelete="CASCADE"), index=True)
    kind = Column(String)
    file_id = Column(String)
    file_name = Column(String, nullable=True)
    created_at = Column(DateTime, default=datetime.now)
    note = relationship("Note", back_populates="attachments")

engine = create_engine("sqlite:///lab_notes.db")
Base.metadata.create_all(engine)

def migrate_db():
    with engine.connect() as conn:
        cols = [row[1] for row in conn.exec_driver_sql("PRAGMA table_info(notes)").fetchall()]
        if "document_id" not in cols:
            conn.exec_driver_sql("ALTER TABLE notes ADD COLUMN document_id VARCHAR")
        if "document_name" not in cols:
            conn.exec_driver_sql("ALTER TABLE notes ADD COLUMN document_name VARCHAR")
        if "updated_at" not in cols:
            conn.exec_driver_sql("ALTER TABLE notes ADD COLUMN updated_at DATETIME")
        conn.commit()

migrate_db()

bot = Bot(token=BOT_TOKEN)
dp = Dispatcher()
user_state = {}

def main_reply_kb():
    return ReplyKeyboardMarkup(
        keyboard=[[KeyboardButton(text="🏠 Главное меню"),
                   KeyboardButton(text="📝 Новая запись")]],
        resize_keyboard=True, is_persistent=True
    )

def is_admin(uid): return uid in ADMIN_IDS

def get_user(uid):
    with Session(engine) as s:
        return s.get(User, uid)

def register_user(uid, name):
    with Session(engine) as s:
        u = s.get(User, uid)
        if u: u.full_name = name
        else: s.add(User(user_id=uid, full_name=name))
        s.commit()

def save_note_with_attachments(uid, category, text, atts):
    u = get_user(uid)
    author = u.full_name if u else f"ID:{uid}"
    with Session(engine) as s:
        n = Note(user_id=uid, author_name=author, category=category, text=text)
        s.add(n); s.flush()
        for a in atts:
            s.add(Attachment(note_id=n.id, kind=a["kind"],
                             file_id=a["file_id"], file_name=a.get("file_name")))
        s.commit()

def get_note(nid):
    with Session(engine) as s:
        return s.get(Note, nid)

def delete_note(nid):
    with Session(engine) as s:
        n = s.get(Note, nid)
        if not n: return False
        s.delete(n); s.commit(); return True

def update_note_text(nid, text):
    with Session(engine) as s:
        n = s.get(Note, nid)
        if not n: return False
        n.text = text; n.updated_at = datetime.now(); s.commit(); return True

def date_range_start(p):
    now = datetime.now(); ts = now.replace(hour=0, minute=0, second=0, microsecond=0)
    return {"today": ts, "yday": ts - timedelta(days=1),
            "7d": ts - timedelta(days=6), "30d": ts - timedelta(days=29)}.get(p)

def date_range_end(p):
    if p == "yday":
        return datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
    return None

def parse_user_date(s):
    s = s.strip()
    for fmt in ["%d.%m.%Y", "%d.%m.%y", "%d.%m"]:
        try:
            dt = datetime.strptime(s, fmt)
            if fmt == "%d.%m": dt = dt.replace(year=datetime.now().year)
            return dt
        except ValueError:
            continue
    return None

def count_notes(user_id=None, category=None, since=None, until=None):
    with Session(engine) as s:
        q = select(func.count(Note.id))
        if user_id: q = q.where(Note.user_id == user_id)
        if category: q = q.where(Note.category == category)
        if since: q = q.where(Note.created_at >= since)
        if until: q = q.where(Note.created_at < until)
        return s.scalar(q) or 0

def get_notes_page(user_id=None, category=None, since=None, until=None, offset=0, limit=PAGE_SIZE):
    with Session(engine) as s:
        q = select(Note).order_by(Note.created_at.desc()).offset(offset).limit(limit)
        if user_id: q = q.where(Note.user_id == user_id)
        if category: q = q.where(Note.category == category)
        if since: q = q.where(Note.created_at >= since)
        if until: q = q.where(Note.created_at < until)
        return s.scalars(q).all()

def get_all_notes_for_export(user_id=None, category=None, since=None, until=None):
    with Session(engine) as s:
        q = select(Note).order_by(Note.created_at.desc())
        if user_id: q = q.where(Note.user_id == user_id)
        if category: q = q.where(Note.category == category)
        if since: q = q.where(Note.created_at >= since)
        if until: q = q.where(Note.created_at < until)
        return s.scalars(q).all()

def get_all_authors():
    with Session(engine) as s:
        q = select(Note.user_id, Note.author_name, func.count(Note.id)).group_by(Note.user_id)
        return s.execute(q).all()

def count_by_category(user_id=None):
    with Session(engine) as s:
        q = select(Note.category, func.count(Note.id)).group_by(Note.category)
        if user_id: q = q.where(Note.user_id == user_id)
        return dict(s.execute(q).all())

def clear_user_notes(uid):
    with Session(engine) as s:
        for n in s.scalars(select(Note).where(Note.user_id == uid)).all():
            s.delete(n)
        s.commit()

def build_csv(user_id=None, category=None, since=None, until=None):
    notes = get_all_notes_for_export(user_id, category, since, until)
    buf = io.StringIO()
    w = csv.writer(buf, delimiter=";")
    w.writerow(["ID","Дата","Изменено","Автор","Категория","Текст","Фото","Документы"])
    for n in notes:
        photos, docs = [], []
        for a in n.attachments:
            if a.kind == "photo": photos.append(a.file_id)
            else: docs.append(f"{a.file_name or 'file'}:{a.file_id}")
        if n.photo_id: photos.append(n.photo_id)
        if n.document_id: docs.append(f"{n.document_name or 'file'}:{n.document_id}")
        w.writerow([n.id, n.created_at.strftime("%d.%m.%Y %H:%M"),
                    n.updated_at.strftime("%d.%m.%Y %H:%M") if n.updated_at else "",
                    n.author_name, CATEGORIES.get(n.category, n.category or ""),
                    (n.text or "").replace("\n"," "), ", ".join(photos), ", ".join(docs)])
    data = buf.getvalue().encode("utf-8-sig")
    return BufferedInputFile(data, filename=f"notes_{datetime.now():%Y%m%d_%H%M}.csv")

def main_menu(uid):
    b = [[InlineKeyboardButton(text="📝 Новая запись", callback_data="new_note")],
         [InlineKeyboardButton(text="📖 Мои записи", callback_data="my_notes")],
         [InlineKeyboardButton(text="📅 По датам", callback_data="by_date")]]
    if is_admin(uid):
        b.append([InlineKeyboardButton(text="📊 Все записи", callback_data="all_notes_0")])
        b.append([InlineKeyboardButton(text="👥 По сотрудникам", callback_data="by_author")])
        b.append([InlineKeyboardButton(text="🗂 По категориям", callback_data="by_category")])
        b.append([InlineKeyboardButton(text="📥 Скачать все (CSV)", callback_data="export_all")])
    b.append([InlineKeyboardButton(text="🗑 Очистить мои записи", callback_data="clear_my")])
    return InlineKeyboardMarkup(inline_keyboard=b)

def category_menu():
    b = [[InlineKeyboardButton(text=n, callback_data=f"cat_{k}")] for k, n in CATEGORIES.items()]
    b.append([InlineKeyboardButton(text="⬅️ В меню", callback_data="main_menu")])
    return InlineKeyboardMarkup(inline_keyboard=b)

def back_menu():
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="⬅️ В меню", callback_data="main_menu")]])

def draft_menu():
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="✅ Готово — сохранить", callback_data="draft_done")],
        [InlineKeyboardButton(text="❌ Отмена", callback_data="draft_cancel")]])

def date_filter_menu():
    b = [[InlineKeyboardButton(text=n, callback_data=f"date_{k}_0")] for k, n in DATE_FILTERS.items()]
    b.append([InlineKeyboardButton(text="🗓 Свой период", callback_data="date_custom")])
    b.append([InlineKeyboardButton(text="⬅️ В меню", callback_data="main_menu")])
    return InlineKeyboardMarkup(inline_keyboard=b)

def pagination_kb(prefix, page, total_pages, notes=None, export_cb=None):
    rows = []
    if notes:
        for n in notes:
            rows.append([
                InlineKeyboardButton(text=f"✏️ #{n.id}", callback_data=f"edit_{n.id}_{prefix}_{page}"),
                InlineKeyboardButton(text=f"🗑 #{n.id}", callback_data=f"del_{n.id}_{prefix}_{page}")])
    nav = []
    if page > 0: nav.append(InlineKeyboardButton(text="⬅️ Назад", callback_data=f"{prefix}_page_{page-1}"))
    nav.append(InlineKeyboardButton(text=f"{page+1}/{total_pages}", callback_data="noop"))
    if page < total_pages - 1: nav.append(InlineKeyboardButton(text="Вперёд ➡️", callback_data=f"{prefix}_page_{page+1}"))
    rows.append(nav)
    if export_cb: rows.append([InlineKeyboardButton(text="📥 Скачать CSV", callback_data=export_cb)])
    rows.append([InlineKeyboardButton(text="⬅️ В меню", callback_data="main_menu")])
    return InlineKeyboardMarkup(inline_keyboard=rows)

async def send_main_menu(message):
    u = get_user(message.from_user.id)
    if not u:
        await message.answer("👋 Добро пожаловать!\n\nСначала зарегистрируйтесь:\n`/register Имя Фамилия`",
                             parse_mode="Markdown", reply_markup=main_reply_kb())
        return
    await message.answer(f"🏠 **Главное меню**\n\nПривет, {u.full_name}!",
                         parse_mode="Markdown", reply_markup=main_menu(message.from_user.id))

@dp.message(Command("start"))
async def cmd_start(message: Message):
    user_state.pop(message.from_user.id, None)
    u = get_user(message.from_user.id)
    if not u:
        await message.answer("👋 Добро пожаловать!\n\nСначала зарегистрируйтесь:\n`/register Имя Фамилия`",
                             parse_mode="Markdown", reply_markup=main_reply_kb())
        return
    await message.answer(f"🏠 **Главное меню**\n\nПривет, {u.full_name}!",
                         parse_mode="Markdown", reply_markup=main_menu(message.from_user.id))

@dp.message(Command("register"))
async def cmd_register(message: Message):
    parts = message.text.split(maxsplit=1)
    if len(parts) < 2 or len(parts[1].strip()) < 3:
        await message.answer("❌ Формат: `/register Имя Фамилия`", parse_mode="Markdown"); return
    register_user(message.from_user.id, parts[1].strip())
    await message.answer(f"✅ Вы зарегистрированы как **{parts[1].strip()}**.",
                         parse_mode="Markdown", reply_markup=main_reply_kb())
    await message.answer("Главное меню:", reply_markup=main_menu(message.from_user.id))

@dp.message(F.text == "🏠 Главное меню")
async def reply_main_menu(message: Message):
    user_state.pop(message.from_user.id, None)
    await send_main_menu(message)

@dp.message(F.text == "📝 Новая запись")
async def reply_new_note(message: Message):
    if not get_user(message.from_user.id):
        await message.answer("⚠️ Сначала `/register Имя Фамилия`", parse_mode="Markdown",
                             reply_markup=main_reply_kb()); return
    user_state[message.from_user.id] = {"action": "await_category"}
    await message.answer("🗂 Выбери категорию записи:", reply_markup=category_menu())

@dp.callback_query(F.data == "new_note")
async def cb_new_note(callback: CallbackQuery):
    if not get_user(callback.from_user.id):
        await callback.answer("Сначала зарегистрируйтесь!", show_alert=True); return
    user_state[callback.from_user.id] = {"action": "await_category"}
    await callback.message.answer("🗂 Выбери категорию записи:", reply_markup=category_menu())
    await callback.answer()

@dp.callback_query(F.data.startswith("cat_"))
async def cb_category_chosen(callback: CallbackQuery):
    key = callback.data.split("_", 1)[1]
    if key not in CATEGORIES:
        await callback.answer("Неизвестная категория", show_alert=True); return
    user_state[callback.from_user.id] = {"action": "draft", "category": key,
                                          "text_parts": [], "attachments": []}
    await callback.message.edit_text(
        f"Категория: **{CATEGORIES[key]}**\n\n"
        f"📝 Отправляй текст, фото и документы (до {MAX_ATTACHMENTS}).\n"
        "Когда закончишь — нажми **✅ Готово**.",
        parse_mode="Markdown", reply_markup=draft_menu())
    await callback.answer()

@dp.callback_query(F.data == "draft_done")
async def cb_draft_done(callback: CallbackQuery):
    st = user_state.get(callback.from_user.id)
    if not st or st.get("action") != "draft":
        await callback.answer("Черновик не найден", show_alert=True); return
    atts = st.get("attachments", [])
    tp = st.get("text_parts", [])
    text = "\n".join(tp) if tp else None
    if not atts and not text:
        await callback.answer("Черновик пуст.", show_alert=True); return
    cat = st["category"]
    save_note_with_attachments(callback.from_user.id, cat, text, atts)
    user_state.pop(callback.from_user.id, None)
    await callback.message.edit_text(f"✅ Запись сохранена в **{CATEGORIES[cat]}**.\nВложений: {len(atts)}.",
                                     parse_mode="Markdown", reply_markup=main_menu(callback.from_user.id))
    await callback.answer("Сохранено")

@dp.callback_query(F.data == "draft_cancel")
async def cb_draft_cancel(callback: CallbackQuery):
    user_state.pop(callback.from_user.id, None)
    await callback.message.edit_text("❌ Черновик отменён.", reply_markup=main_menu(callback.from_user.id))
    await callback.answer("Отменено")

@dp.callback_query(F.data == "main_menu")
async def cb_main_menu(callback: CallbackQuery):
    user_state.pop(callback.from_user.id, None)
    await callback.message.edit_text("🏠 **Главное меню**", parse_mode="Markdown",
                                     reply_markup=main_menu(callback.from_user.id))
    await callback.answer()

@dp.callback_query(F.data == "noop")
async def cb_noop(callback: CallbackQuery):
    await callback.answer()

@dp.callback_query(F.data == "by_date")
async def cb_by_date(callback: CallbackQuery):
    user_state.pop(callback.from_user.id, None)
    await callback.message.edit_text("📅 **Выбери период:**", parse_mode="Markdown",
                                     reply_markup=date_filter_menu())
    await callback.answer()

@dp.callback_query(F.data == "date_custom")
async def cb_date_custom(callback: CallbackQuery):
    user_state[callback.from_user.id] = {"action": "await_custom_date"}
    await callback.message.edit_text(
        "🗓 **Свой период**\n\nОтправь одну или две даты в формате **ДД.ММ.ГГГГ**.\n"
        "Примеры: `21.09.2026`, `01.09.2026 15.09.2026`, `21.09`",
        parse_mode="Markdown",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="❌ Отмена", callback_data="by_date")]]))
    await callback.answer()

@dp.callback_query(F.data.startswith("date_"))
async def cb_date_chosen(callback: CallbackQuery):
    if callback.data == "date_custom": return
    parts = callback.data.split("_")
    period = parts[1]; page = int(parts[2])
    if period not in DATE_FILTERS:
        await callback.answer("Неизвестный период", show_alert=True); return
    await show_page(callback.message, f"date_{period}", page, edit=True)
    await callback.answer()

@dp.callback_query(F.data.startswith("edit_"))
async def cb_edit_request(callback: CallbackQuery):
    parts = callback.data.split("_")
    nid = int(parts[1]); page = int(parts[-1]); prefix = "_".join(parts[2:-1])
    n = get_note(nid)
    if not n:
        await callback.answer("Запись уже удалена.", show_alert=True); return
    if not (n.user_id == callback.from_user.id or is_admin(callback.from_user.id)):
        await callback.answer("⛔ Только свои записи.", show_alert=True); return
    user_state[callback.from_user.id] = {"action": "await_edit", "note_id": nid,
                                          "prefix": prefix, "page": page}
    cat = CATEGORIES.get(n.category, n.category or "—")
    cur = n.text if n.text else "_(пусто)_"
    await callback.message.answer(
        f"✏️ **Редактирование #{nid}**\n\n🗂 {cat}\n👤 {n.author_name}\n"
        f"🕒 {n.created_at.strftime('%d.%m.%Y %H:%M')}\n\n📝 Текущий текст:\n{cur}\n\n"
        "Отправь **новый текст**.",
        parse_mode="Markdown",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="❌ Отмена", callback_data=f"editcancel_{prefix}_{page}")]]))
    await callback.answer()

@dp.callback_query(F.data.startswith("editcancel_"))
async def cb_edit_cancel(callback: CallbackQuery):
    parts = callback.data.split("_")
    page = int(parts[-1]); prefix = "_".join(parts[1:-1])
    user_state.pop(callback.from_user.id, None)
    await callback.message.edit_text("❌ Редактирование отменено.")
    await show_page(callback.message, prefix, page, edit=False)
    await callback.answer()

@dp.callback_query(F.data.startswith("del_"))
async def cb_delete_request(callback: CallbackQuery):
    parts = callback.data.split("_")
    nid = int(parts[1]); page = int(parts[-1]); prefix = "_".join(parts[2:-1])
    n = get_note(nid)
    if not n:
        await callback.answer("Запись уже удалена.", show_alert=True); return
    if not (n.user_id == callback.from_user.id or is_admin(callback.from_user.id)):
        await callback.answer("⛔ Только свои записи.", show_alert=True); return
    cat = CATEGORIES.get(n.category, n.category or "—")
    prev = (n.text or "")[:200]
    text = (f"⚠️ **Удалить запись #{n.id}?**\n\n🗂 {cat}\n👤 {n.author_name}\n"
            f"🕒 {n.created_at.strftime('%d.%m.%Y %H:%M')}")
    if prev: text += f"\n\n📝 {prev}"
    kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="✅ Да, удалить", callback_data=f"delok_{nid}_{prefix}_{page}")],
        [InlineKeyboardButton(text="❌ Отмена", callback_data=f"{prefix}_page_{page}")]])
    await callback.message.answer(text, parse_mode="Markdown", reply_markup=kb)
    await callback.answer()

@dp.callback_query(F.data.startswith("delok_"))
async def cb_delete_confirm(callback: CallbackQuery):
    parts = callback.data.split("_")
    nid = int(parts[1]); page = int(parts[-1]); prefix = "_".join(parts[2:-1])
    n = get_note(nid)
    if not n:
        await callback.answer("Запись уже удалена.", show_alert=True); return
    if not (n.user_id == callback.from_user.id or is_admin(callback.from_user.id)):
        await callback.answer("⛔ Недостаточно прав.", show_alert=True); return
    delete_note(nid)
    await callback.message.edit_text(f"🗑 Запись #{nid} удалена.")
    await callback.answer("Удалено")
    await show_page(callback.message, prefix, page, edit=False)

async def show_page(target_message, prefix, page, edit=True):
    uid_f = cat_f = since = until = export_cb = None
    title = ""
    if prefix == "myall":
        title = "📖 **Все мои записи**"; export_cb = "export_my"; uid_f = target_message.chat.id
    elif prefix.startswith("mycat_"):
        k = prefix.replace("mycat_", ""); cat_f = k
        title = f"📖 **{CATEGORIES.get(k, k)}**"; export_cb = f"export_my_{k}"
        uid_f = target_message.chat.id
    elif prefix == "all":
        title = "📊 **Все записи сотрудников**"; export_cb = "export_all"
    elif prefix.startswith("author_"):
        uid_f = int(prefix.replace("author_", ""))
        title = "📋 **Записи сотрудника**"; export_cb = f"export_author_{uid_f}"
    elif prefix.startswith("catpage_"):
        k = prefix.replace("catpage_", ""); cat_f = k
        title = f"🗂 **{CATEGORIES.get(k, k)}**"; export_cb = f"export_cat_{k}"
    elif prefix.startswith("date_"):
        period = prefix.replace("date_", "")
        if period not in DATE_FILTERS: return
        since = date_range_start(period); until = date_range_end(period)
        title = f"📅 **{DATE_FILTERS[period]}**"; export_cb = f"export_date_{period}"
        if not is_admin(target_message.chat.id): uid_f = target_message.chat.id
    elif prefix.startswith("range_"):
        p = prefix.split("_")
        try:
            d1 = datetime.strptime(p[1], "%Y%m%d"); d2 = datetime.strptime(p[2], "%Y%m%d")
        except Exception: return
        since = d1; until = d2 + timedelta(days=1)
        title = f"🗓 **{d1.strftime('%d.%m.%Y')} — {d2.strftime('%d.%m.%Y')}**"
        export_cb = f"export_range_{p[1]}_{p[2]}"
        if not is_admin(target_message.chat.id): uid_f = target_message.chat.id
    total = count_notes(uid_f, cat_f, since, until)
    total_pages = max(1, (total + PAGE_SIZE - 1) // PAGE_SIZE)
    if page >= total_pages: page = total_pages - 1
    notes = get_notes_page(uid_f, cat_f, since, until, page * PAGE_SIZE)
    if not notes:
        text = f"{title}\n\n_Записей нет._"
        kb = InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="📅 Другой период", callback_data="by_date")],
            [InlineKeyboardButton(text="⬅️ В меню", callback_data="main_menu")]])
    else:
        text = f"{title} (стр. {page+1}/{total_pages}, всего {total})\n\n" + format_notes(notes)
        kb = pagination_kb(prefix, page, total_pages, notes=notes, export_cb=export_cb)
    if edit:
        try: await target_message.edit_text(text, parse_mode="Markdown", reply_markup=kb)
        except Exception: await target_message.answer(text, parse_mode="Markdown", reply_markup=kb)
    else:
        await target_message.answer(text, parse_mode="Markdown", reply_markup=kb)
    if notes: await send_attachments(target_message, notes)

@dp.callback_query(F.data == "my_notes")
async def cb_my_notes(callback: CallbackQuery):
    counts = count_by_category(user_id=callback.from_user.id)
    if not counts:
        await callback.message.answer("У тебя пока нет записей.", reply_markup=back_menu())
        await callback.answer(); return
    b = [[InlineKeyboardButton(text=f"{n} ({counts.get(k,0)})", callback_data=f"mycat_{k}_0")]
         for k, n in CATEGORIES.items()]
    b.append([InlineKeyboardButton(text="📋 Все мои записи", callback_data="myall_page_0")])
    b.append([InlineKeyboardButton(text="📅 По датам", callback_data="by_date")])
    b.append([InlineKeyboardButton(text="⬅️ В меню", callback_data="main_menu")])
    await callback.message.edit_text("📖 **Мои записи по категориям:**",
                                     parse_mode="Markdown",
                                     reply_markup=InlineKeyboardMarkup(inline_keyboard=b))
    await callback.answer()

@dp.callback_query(F.data.startswith("myall_page_"))
async def cb_myall_page(callback: CallbackQuery):
    page = int(callback.data.split("_")[-1])
    await show_page(callback.message, "myall", page, edit=True)
    await callback.answer()

@dp.callback_query(F.data.startswith("mycat_"))
async def cb_mycat_page(callback: CallbackQuery):
    parts = callback.data.split("_")
    await show_page(callback.message, f"mycat_{parts[1]}", int(parts[2]), edit=True)
    await callback.answer()

@dp.callback_query(F.data.startswith("all_notes_"))
async def cb_all_notes(callback: CallbackQuery):
    if not is_admin(callback.from_user.id):
        await callback.answer("⛔ Только для наблюдателей.", show_alert=True); return
    page = int(callback.data.split("_")[-1])
    await show_page(callback.message, "all", page, edit=True)
    await callback.answer()

@dp.callback_query(F.data.startswith("all_page_"))
async def cb_all_page(callback: CallbackQuery):
    if not is_admin(callback.from_user.id):
        await callback.answer("⛔ Доступ запрещён.", show_alert=True); return
    page = int(callback.data.split("_")[-1])
    await show_page(callback.message, "all", page, edit=True)
    await callback.answer()

@dp.callback_query(F.data == "by_author")
async def cb_by_author(callback: CallbackQuery):
    if not is_admin(callback.from_user.id):
        await callback.answer("⛔ Только для наблюдателей.", show_alert=True); return
    authors = get_all_authors()
    if not authors:
        await callback.message.answer("Пока нет записей.", reply_markup=back_menu())
        await callback.answer(); return
    b = [[InlineKeyboardButton(text=f"{n} ({c})", callback_data=f"author_{u}_0")]
         for u, n, c in authors]
    b.append([InlineKeyboardButton(text="⬅️ В меню", callback_data="main_menu")])
    await callback.message.edit_text("👥 **Выбери сотрудника:**", parse_mode="Markdown",
                                     reply_markup=InlineKeyboardMarkup(inline_keyboard=b))
    await callback.answer()

@dp.callback_query(F.data.startswith("author_"))
async def cb_author_notes(callback: CallbackQuery):
    if not is_admin(callback.from_user.id):
        await callback.answer("⛔ Доступ запрещён.", show_alert=True); return
    parts = callback.data.split("_")
    await show_page(callback.message, f"author_{parts[1]}", int(parts[2]), edit=True)
    await callback.answer()

@dp.callback_query(F.data == "by_category")
async def cb_by_category(callback: CallbackQuery):
    if not is_admin(callback.from_user.id):
        await callback.answer("⛔ Только для наблюдателей.", show_alert=True); return
    counts = count_by_category()
    if not counts:
        await callback.message.answer("Записей нет.", reply_markup=back_menu())
        await callback.answer(); return
    b = [[InlineKeyboardButton(text=f"{n} ({counts.get(k,0)})", callback_data=f"catpage_{k}_0")]
         for k, n in CATEGORIES.items()]
    b.append([InlineKeyboardButton(text="⬅️ В меню", callback_data="main_menu")])
    await callback.message.edit_text("🗂 **Записи по категориям:**", parse_mode="Markdown",
                                     reply_markup=InlineKeyboardMarkup(inline_keyboard=b))
    await callback.answer()

@dp.callback_query(F.data.startswith("catpage_"))
async def cb_catpage(callback: CallbackQuery):
    if not is_admin(callback.from_user.id):
        await callback.answer("⛔ Доступ запрещён.", show_alert=True); return
    parts = callback.data.split("_")
    await show_page(callback.message, f"catpage_{parts[1]}", int(parts[2]), edit=True)
    await callback.answer()

@dp.callback_query(F.data == "export_all")
async def cb_export_all(callback: CallbackQuery):
    if not is_admin(callback.from_user.id):
        await callback.answer("⛔ Только для наблюдателей.", show_alert=True); return
    await callback.answer("Готовлю файл...")
    await callback.message.answer_document(build_csv(), caption="📥 Все записи (CSV)")

@dp.callback_query(F.data == "export_my")
async def cb_export_my(callback: CallbackQuery):
    await callback.answer("Готовлю файл...")
    await callback.message.answer_document(build_csv(user_id=callback.from_user.id),
                                            caption="📥 Мои записи (CSV)")

@dp.callback_query(F.data.startswith("export_my_"))
async def cb_export_my_cat(callback: CallbackQuery):
    k = callback.data.replace("export_my_", "")
    await callback.answer("Готовлю файл...")
    await callback.message.answer_document(build_csv(user_id=callback.from_user.id, category=k),
                                            caption=f"📥 {CATEGORIES.get(k, k)} (CSV)")

@dp.callback_query(F.data.startswith("export_cat_"))
async def cb_export_cat(callback: CallbackQuery):
    if not is_admin(callback.from_user.id):
        await callback.answer("⛔ Доступ запрещён.", show_alert=True); return
    k = callback.data.replace("export_cat_", "")
    await callback.answer("Готовлю файл...")
    await callback.message.answer_document(build_csv(category=k),
                                            caption=f"📥 {CATEGORIES.get(k, k)} (CSV)")

@dp.callback_query(F.data.startswith("export_author_"))
async def cb_export_author(callback: CallbackQuery):
    if not is_admin(callback.from_user.id):
        await callback.answer("⛔ Доступ запрещён.", show_alert=True); return
    uid = int(callback.data.replace("export_author_", ""))
    await callback.answer("Готовлю файл...")
    await callback.message.answer_document(build_csv(user_id=uid),
                                            caption="📥 Записи сотрудника (CSV)")

@dp.callback_query(F.data.startswith("export_date_"))
async def cb_export_date(callback: CallbackQuery):
    p = callback.data.replace("export_date_", "")
    if p not in DATE_FILTERS:
        await callback.answer("Неизвестный период", show_alert=True); return
    uid_f = None if is_admin(callback.from_user.id) else callback.from_user.id
    await callback.answer("Готовлю файл...")
    await callback.message.answer_document(
        build_csv(user_id=uid_f, since=date_range_start(p), until=date_range_end(p)),
        caption=f"📥 {DATE_FILTERS[p]} (CSV)")

@dp.callback_query(F.data.startswith("export_range_"))
async def cb_export_range(callback: CallbackQuery):
    p = callback.data.split("_")
    try:
        d1 = datetime.strptime(p[2], "%Y%m%d"); d2 = datetime.strptime(p[3], "%Y%m%d")
    except Exception:
        await callback.answer("Ошибка дат", show_alert=True); return
    uid_f = None if is_admin(callback.from_user.id) else callback.from_user.id
    await callback.answer("Готовлю файл...")
    await callback.message.answer_document(
        build_csv(user_id=uid_f, since=d1, until=d2 + timedelta(days=1)),
        caption=f"📥 {d1.strftime('%d.%m.%Y')} — {d2.strftime('%d.%m.%Y')} (CSV)")

@dp.callback_query(F.data == "clear_my")
async def cb_clear_my(callback: CallbackQuery):
    clear_user_notes(callback.from_user.id)
    await callback.message.answer("🗑 Все твои записи удалены.", reply_markup=back_menu())
    await callback.answer()

def format_notes(notes):
    lines = []
    for i, n in enumerate(notes, 1):
        cat = CATEGORIES.get(n.category, n.category or "—")
        line = (f"{i}. 🆔 #{n.id}\n   🗂 {cat}\n   👤 {n.author_name}\n"
                f"   🕒 {n.created_at.strftime('%d.%m.%Y %H:%M')}")
        if n.updated_at: line += f" (изм. {n.updated_at.strftime('%d.%m %H:%M')})"
        if n.text:
            t = n.text[:300] + ("..." if len(n.text) > 300 else "")
            line += f"\n   📝 {t}"
        photos = sum(1 for a in n.attachments if a.kind == "photo") + (1 if n.photo_id else 0)
        docs = sum(1 for a in n.attachments if a.kind == "document") + (1 if n.document_id else 0)
        if photos: line += f"\n   📷 фото: {photos}"
        if docs: line += f"\n   📎 документов: {docs}"
        lines.append(line)
    return "\n\n".join(lines)

async def send_attachments(target_message, notes):
    for n in notes:
        cat = CATEGORIES.get(n.category, n.category or "—")
        header = (f"🗂 {cat}\n👤 {n.author_name}\n"
                  f"🕒 {n.created_at.strftime('%d.%m.%Y %H:%M')}")
        if n.updated_at: header += f"\n✏️ изменено {n.updated_at.strftime('%d.%m.%Y %H:%M')}"
        # Фото из attachments
        for a in n.attachments:
            if a.kind == "photo":
                cap = header + (f"\n\n{n.text}" if n.text else "")
                try:
                    await target_message.answer_photo(photo=a.file_id, caption=cap[:1024])
                except Exception as e:
                    logging.warning(f"photo err: {e}")
            elif a.kind == "document":
                cap = header + (f"\n📎 {a.file_name}" if a.file_name else "")
                try:
                    await target_message.answer_document(document=a.file_id, caption=cap[:1024])
                except Exception as e:
                    logging.warning(f"doc err: {e}")
        # Старые одиночные поля
        if n.photo_id:
            cap = header + (f"\n\n{n.text}" if n.text else "")
            try: await target_message.answer_photo(photo=n.photo_id, caption=cap[:1024])
            except Exception as e: logging.warning(f"old photo err: {e}")
        if n.document_id:
            cap = header + (f"\n📎 {n.document_name}" if n.document_name else "")
            try: await target_message.answer_document(document=n.document_id, caption=cap[:1024])
            except Exception as e: logging.warning(f"old doc err: {e}")

@dp.message(F.photo)
async def handle_photo(message: Message):
    st = user_state.get(message.from_user.id)
    if not st or st.get("action") != "draft":
        await message.answer("⚠️ Нажми **📝 Новая запись** или кнопку внизу.",
                             reply_markup=main_reply_kb()); return
    if len(st["attachments"]) >= MAX_ATTACHMENTS:
        await message.answer(f"⚠️ Максимум {MAX_ATTACHMENTS} вложений."); return
    st["attachments"].append({"kind": "photo", "file_id": message.photo[-1].file_id})
    if message.caption: st["text_parts"].append(message.caption)
    await message.answer(f"📷 Добавлено фото ({len(st['attachments'])}/{MAX_ATTACHMENTS}).",
                         reply_markup=draft_menu())

@dp.message(F.document)
async def handle_document(message: Message):
    st = user_state.get(message.from_user.id)
    if not st or st.get("action") != "draft":
        await message.answer("⚠️ Нажми **📝 Новая запись** или кнопку внизу.",
                             reply_markup=main_reply_kb()); return
    if len(st["attachments"]) >= MAX_ATTACHMENTS:
        await message.answer(f"⚠️ Максимум {MAX_ATTACHMENTS} вложений."); return
    st["attachments"].append({"kind": "document", "file_id": message.document.file_id,
                              "file_name": message.document.file_name or "файл"})
    if message.caption: st["text_parts"].append(message.caption)
    await message.answer(f"📎 Добавлен документ ({len(st['attachments'])}/{MAX_ATTACHMENTS}).",
                         reply_markup=draft_menu())

@dp.message(F.text)
async def handle_text(message: Message):
    if message.text.startswith("/"): return
    st = user_state.get(message.from_user.id)

    if st and st.get("action") == "await_custom_date":
        raw = message.text.replace(" - ", " ").replace(" по ", " ").replace("-", " ").replace("—", " ")
        parts = [p for p in raw.split() if p]
        if len(parts) == 1:
            d1 = parse_user_date(parts[0])
            if not d1:
                await message.answer("❌ Пример: `21.09.2026` или `01.09.2026 15.09.2026`",
                                     parse_mode="Markdown"); return
            d1 = d1.replace(hour=0, minute=0, second=0, microsecond=0); d2 = d1
        elif len(parts) == 2:
            d1 = parse_user_date(parts[0]); d2 = parse_user_date(parts[1])
            if not d1 or not d2:
                await message.answer("❌ Пример: `01.09.2026 15.09.2026`",
                                     parse_mode="Markdown"); return
            d1 = d1.replace(hour=0, minute=0, second=0, microsecond=0)
            d2 = d2.replace(hour=0, minute=0, second=0, microsecond=0)
            if d1 > d2: d1, d2 = d2, d1
        else:
            await message.answer("❌ Слишком много дат.", reply_markup=back_menu()); return
        user_state.pop(message.from_user.id, None)
        await show_page(message, f"range_{d1:%Y%m%d}_{d2:%Y%m%d}", 0, edit=False)
        return

    if st and st.get("action") == "await_edit":
        update_note_text(st["note_id"], message.text)
        pref, pg = st["prefix"], st["page"]
        user_state.pop(message.from_user.id, None)
        await message.answer(f"✅ Запись #{st['note_id']} обновлена.")
        await show_page(message, pref, pg, edit=False)
        return

    if st and st.get("action") == "draft":
        st["text_parts"].append(message.text)
        await message.answer("📝 Текст добавлен. Отправляй ещё или нажми **✅ Готово**.",
                             reply_markup=draft_menu())
        return

    await message.answer("⚠️ Нажми **📝 Новая запись** или кнопку внизу.",
                         reply_markup=main_reply_kb())

async def main():
    print("Бот запущен...")
    await dp.start_polling(bot)

if __name__ == "__main__":
    asyncio.run(main())
