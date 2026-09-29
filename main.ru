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
    KeyboardButton, ReplyKeyboardRemove
)
from sqlalchemy import (
    create_engine, Column, Integer, String, DateTime,
    BigInteger, ForeignKey, select, func
)
from sqlalchemy.orm import DeclarativeBase, Session, relationship

# ============ НАСТРОЙКИ ============
BOT_TOKEN = "8365458785:AAHyVIla42H9kRKG0oT8SQvjiOFiWjOeTSE"

ADMIN_IDS = [
    1170348114,
    358930137,
]

PAGE_SIZE = 10
MAX_ATTACHMENTS = 20

logging.basicConfig(level=logging.INFO)

# ============ КАТЕГОРИИ ============
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

# ============ БАЗА ============
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

    attachments = relationship(
        "Attachment", back_populates="note",
        cascade="all, delete-orphan", order_by="Attachment.id"
    )

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

# ============ ИНИЦИАЛИЗАЦИЯ ============
bot = Bot(token=BOT_TOKEN)
dp = Dispatcher()
user_state = {}

# ============ REPLY-КЛАВИАТУРА (постоянные кнопки внизу) ============
def main_reply_kb():
    kb = ReplyKeyboardMarkup(
        keyboard=[
            [KeyboardButton(text="🏠 Главное меню"), KeyboardButton(text="📝 Новая запись")],
        ],
        resize_keyboard=True,
        is_persistent=True,
    )
    return kb

# ============ ХЕЛПЕРЫ ============
def is_admin(user_id: int) -> bool:
    return user_id in ADMIN_IDS

def get_user(user_id: int):
    with Session(engine) as session:
        return session.get(User, user_id)

def register_user(user_id: int, full_name: str):
    with Session(engine) as session:
        user = session.get(User, user_id)
        if user:
            user.full_name = full_name
        else:
            session.add(User(user_id=user_id, full_name=full_name))
        session.commit()

def save_note_with_attachments(user_id, category, text, attachments):
    user = get_user(user_id)
    author = user.full_name if user else f"ID:{user_id}"
    with Session(engine) as session:
        note = Note(user_id=user_id, author_name=author,
                    category=category, text=text)
        session.add(note)
        session.flush()
        for att in attachments:
            session.add(Attachment(
                note_id=note.id,
                kind=att["kind"],
                file_id=att["file_id"],
                file_name=att.get("file_name"),
            ))
        session.commit()

def get_note(note_id: int):
    with Session(engine) as session:
        return session.get(Note, note_id)

def delete_note(note_id: int) -> bool:
    with Session(engine) as session:
        note = session.get(Note, note_id)
        if not note:
            return False
        session.delete(note)
        session.commit()
        return True

def update_note_text(note_id: int, new_text: str) -> bool:
    with Session(engine) as session:
        note = session.get(Note, note_id)
        if not note:
            return False
        note.text = new_text
        note.updated_at = datetime.now()
        session.commit()
        return True

def date_range_start(period: str):
    now = datetime.now()
    today_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    if period == "today":
        return today_start
    if period == "yday":
        return today_start - timedelta(days=1)
    if period == "7d":
        return today_start - timedelta(days=6)
    if period == "30d":
        return today_start - timedelta(days=29)
    return None

def date_range_end(period: str):
    if period == "yday":
        return datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
    return None

def parse_user_date(s: str):
    s = s.strip()
    for fmt in ["%d.%m.%Y", "%d.%m.%y", "%d.%m"]:
        try:
            dt = datetime.strptime(s, fmt)
            if fmt == "%d.%m":
                dt = dt.replace(year=datetime.now().year)
            return dt
        except ValueError:
            continue
    return None

def count_notes(user_id=None, category=None, since=None, until=None) -> int:
    with Session(engine) as session:
        stmt = select(func.count(Note.id))
        if user_id:
            stmt = stmt.where(Note.user_id == user_id)
        if category:
            stmt = stmt.where(Note.category == category)
        if since:
            stmt = stmt.where(Note.created_at >= since)
        if until:
            stmt = stmt.where(Note.created_at < until)
        return session.scalar(stmt) or 0

def get_notes_page(user_id=None, category=None, since=None, until=None,
                   offset=0, limit=PAGE_SIZE):
    with Session(engine) as session:
        stmt = select(Note).order_by(Note.created_at.desc()).offset(offset).limit(limit)
        if user_id:
            stmt = stmt.where(Note.user_id == user_id)
        if category:
            stmt = stmt.where(Note.category == category)
        if since:
            stmt = stmt.where(Note.created_at >= since)
        if until:
            stmt = stmt.where(Note.created_at < until)
        return session.scalars(stmt).all()

def get_all_notes_for_export(user_id=None, category=None, since=None, until=None):
    with Session(engine) as session:
        stmt = select(Note).order_by(Note.created_at.desc())
        if user_id:
            stmt = stmt.where(Note.user_id == user_id)
        if category:
            stmt = stmt.where(Note.category == category)
        if since:
            stmt = stmt.where(Note.created_at >= since)
        if until:
            stmt = stmt.where(Note.created_at < until)
        return session.scalars(stmt).all()

def get_all_authors():
    with Session(engine) as session:
        stmt = select(Note.user_id, Note.author_name, func.count(Note.id)).group_by(Note.user_id)
        return session.execute(stmt).all()

def count_by_category(user_id=None):
    with Session(engine) as session:
        stmt = select(Note.category, func.count(Note.id)).group_by(Note.category)
        if user_id:
            stmt = stmt.where(Note.user_id == user_id)
        return dict(session.execute(stmt).all())

def clear_user_notes(user_id: int):
    with Session(engine) as session:
        notes = session.scalars(select(Note).where(Note.user_id == user_id)).all()
        for n in notes:
            session.delete(n)
        session.commit()

# ============ CSV ============
def build_csv(user_id=None, category=None, since=None, until=None) -> BufferedInputFile:
    notes = get_all_notes_for_export(user_id=user_id, category=category,
                                     since=since, until=until)
    buf = io.StringIO()
    writer = csv.writer(buf, delimiter=";")
    writer.writerow([
        "ID", "Дата", "Изменено", "Автор", "Категория", "Текст",
        "Фото (file_id)", "Документы"
    ])
    for n in notes:
        photos = []
        docs = []
        for att in n.attachments:
            if att.kind == "photo":
                photos.append(att.file_id)
            else:
                docs.append(f"{att.file_name or 'file'}:{att.file_id}")
        if n.photo_id:
            photos.append(n.photo_id)
        if n.document_id:
            docs.append(f"{n.document_name or 'file'}:{n.document_id}")
        writer.writerow([
            n.id,
            n.created_at.strftime("%d.%m.%Y %H:%M"),
            n.updated_at.strftime("%d.%m.%Y %H:%M") if n.updated_at else "",
            n.author_name,
            CATEGORIES.get(n.category, n.category or ""),
            (n.text or "").replace("\n", " "),
            ", ".join(photos),
            ", ".join(docs),
        ])
    data = buf.getvalue().encode("utf-8-sig")
    filename = f"notes_{datetime.now().strftime('%Y%m%d_%H%M')}.csv"
    return BufferedInputFile(data, filename=filename)

# ============ INLINE-КЛАВИАТУРЫ ============
def main_menu(user_id: int):
    buttons = [
        [InlineKeyboardButton(text="📝 Новая запись", callback_data="new_note")],
        [InlineKeyboardButton(text="📖 Мои записи", callback_data="my_notes")],
        [InlineKeyboardButton(text="📅 По датам", callback_data="by_date")],
    ]
    if is_admin(user_id):
        buttons.append([InlineKeyboardButton(text="📊 Все записи", callback_data="all_notes_0")])
        buttons.append([InlineKeyboardButton(text="👥 По сотрудникам", callback_data="by_author")])
        buttons.append([InlineKeyboardButton(text="🗂 По категориям", callback_data="by_category")])
        buttons.append([InlineKeyboardButton(text="📥 Скачать все (CSV)", callback_data="export_all")])
    buttons.append([InlineKeyboardButton(text="🗑 Очистить мои записи", callback_data="clear_my")])
    return InlineKeyboardMarkup(inline_keyboard=buttons)

def category_menu():
    buttons = [[InlineKeyboardButton(text=name, callback_data=f"cat_{key}")]
               for key, name in CATEGORIES.items()]
    buttons.append([InlineKeyboardButton(text="⬅️ В меню", callback_data="main_menu")])
    return InlineKeyboardMarkup(inline_keyboard=buttons)

def back_menu():
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="⬅️ В меню", callback_data="main_menu")]
    ])

def draft_menu():
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="✅ Готово — сохранить", callback_data="draft_done")],
        [InlineKeyboardButton(text="❌ Отмена", callback_data="draft_cancel")],
    ])

def date_filter_menu():
    buttons = [[InlineKeyboardButton(text=name, callback_data=f"date_{key}_0")]
               for key, name in DATE_FILTERS.items()]
    buttons.append([InlineKeyboardButton(text="🗓 Свой период", callback_data="date_custom")])
    buttons.append([InlineKeyboardButton(text="⬅️ В меню", callback_data="main_menu")])
    return InlineKeyboardMarkup(inline_keyboard=buttons)

def pagination_kb(prefix, page, total_pages, notes=None, export_cb=None):
    rows = []
    if notes:
        for n in notes:
            rows.append([
                InlineKeyboardButton(text=f"✏️ #{n.id}", callback_data=f"edit_{n.id}_{prefix}_{page}"),
                InlineKeyboardButton(text=f"🗑 #{n.id}", callback_data=f"del_{n.id}_{prefix}_{page}"),
            ])
    nav = []
    if page > 0:
        nav.append(InlineKeyboardButton(text="⬅️ Назад", callback_data=f"{prefix}_page_{page-1}"))
    nav.append(InlineKeyboardButton(text=f"{page+1}/{total_pages}", callback_data="noop"))
    if page < total_pages - 1:
        nav.append(InlineKeyboardButton(text="Вперёд ➡️", callback_data=f"{prefix}_page_{page+1}"))
    rows.append(nav)
    if export_cb:
        rows.append([InlineKeyboardButton(text="📥 Скачать CSV", callback_data=export_cb)])
    rows.append([InlineKeyboardButton(text="⬅️ В меню", callback_data="main_menu")])
    return InlineKeyboardMarkup(inline_keyboard=rows)

# ============ ВСПОМОГАТЕЛЬНОЕ: отправить главное меню ============
async def send_main_menu(message: Message):
    user = get_user(message.from_user.id)
    if not user:
        await message.answer(
            "👋 Добро пожаловать!\n\n"
            "Сначала зарегистрируйтесь:\n"
            "`/register Имя Фамилия`",
            parse_mode="Markdown",
            reply_markup=main_reply_kb()
        )
        return
    await message.answer(
        f"🏠 **Главное меню**\n\nПривет, {user.full_name}!",
        parse_mode="Markdown",
        reply_markup=main_menu(message.from_user.id)
    )

# ============ КОМАНДЫ ============
@dp.message(Command("start"))
async def cmd_start(message: Message):
    user_state.pop(message.from_user.id, None)
    # Показываем Reply-клавиатуру всегда при /start
    user = get_user(message.from_user.id)
    if not user:
        await message.answer(
            "👋 Добро пожаловать в лабораторный журнал!\n\n"
            "Сначала зарегистрируйтесь:\n"
            "`/register Имя Фамилия`",
            parse_mode="Markdown",
            reply_markup=main_reply_kb()
        )
        return
    await message.answer(
        f"🏠 **Главное меню**\n\nПривет, {user.full_name}!",
        parse_mode="Markdown",
        reply_markup=main_menu(message.from_user.id)
    )
    # Дополнительно — Reply-клавиатура (если её не было)
    await message.answer("Кнопки внизу всегда под рукой 👇", reply_markup=main_reply_kb())

@dp.message(Command("register"))
async def cmd_register(message: Message):
    parts = message.text.split(maxsplit=1)
    if len(parts) < 2 or len(parts[1].strip()) < 3:
        await message.answer("❌ Формат: `/register Имя Фамилия`", parse_mode="Markdown")
        return
    full_name = parts[1].strip()
    register_user(message.from_user.id, full_name)
    await message.answer(
        f"✅ Вы зарегистрированы как **{full_name}**.",
        parse_mode="Markdown",
        reply_markup=main_reply_kb()
    )
    await message.answer(
        "Главное меню:",
        reply_markup=main_menu(message.from_user.id)
    )

# ============ REPLY-КНОПКИ (постоянные внизу) ============
@dp.message(F.text == "🏠 Главное меню")
async def reply_main_menu(message: Message):
    user_state.pop(message.from_user.id, None)
    await send_main_menu(message)

@dp.message(F.text == "📝 Новая запись")
async def reply_new_note(message: Message):
    if not get_user(message.from_user.id):
        await message.answer("⚠️ Сначала зарегистрируйтесь: `/register Имя Фамилия`",
                             parse_mode="Markdown", reply_markup=main_reply_kb())
        return
    user_state[message.from_user.id] = {"action": "await_category"}
    await message.answer("🗂 Выбери категорию записи:", reply_markup=category_menu())

# ============ НОВАЯ ЗАПИСЬ ============
@dp.callback_query(F.data == "new_note")
async def cb_new_note(callback: CallbackQuery):
    if not get_user(callback.from_user.id):
        await callback.answer("Сначала зарегистрируйтесь!", show_alert=True)
        return
    user_state[callback.from_user.id] = {"action": "await_category"}
    await callback.message.answer("🗂 Выбери категорию записи:", reply_markup=category_menu())
    await callback.answer()

@dp.callback_query(F.data.startswith("cat_"))
async def cb_category_chosen(callback: CallbackQuery):
    key = callback.data.split("_", 1)[1]
    if key not in CATEGORIES:
        await callback.answer("Неизвестная категория", show_alert=True)
        return
    user_state[callback.from_user.id] = {
        "action": "draft",
        "category": key,
        "text_parts": [],
        "attachments": [],
    }
    await callback.message.edit_text(
        f"Категория: **{CATEGORIES[key]}**\n\n"
        f"📝 Отправляй текст, фото или документы (до {MAX_ATTACHMENTS} вложений).\n"
        "Можно чередовать: фото, подпись, ещё фото, документ и т.д.\n\n"
        "Когда закончишь — нажми **✅ Готово**.",
        parse_mode="Markdown",
        reply_markup=draft_menu()
    )
    await callback.answer()

@dp.callback_query(F.data == "draft_done")
async def cb_draft_done(callback: CallbackQuery):
    state = user_state.get(callback.from_user.id)
    if not state or state.get("action") != "draft":
        await callback.answer("Черновик не найден", show_alert=True)
        return
    atts = state.get("attachments", [])
    text_parts = state.get("text_parts", [])
    text = "\n".join(text_parts) if text_parts else None
    if not atts and not text:
        await callback.answer("Черновик пуст. Добавь текст, фото или документ.", show_alert=True)
        return
    category = state["category"]
    save_note_with_attachments(callback.from_user.id, category, text, atts)
    user_state.pop(callback.from_user.id, None)
    await callback.message.edit_text(
        f"✅ Запись сохранена в категорию **{CATEGORIES[category]}**.\n"
        f"Вложений: {len(atts)}.",
        parse_mode="Markdown",
        reply_markup=main_menu(callback.from_user.id)
    )
    await callback.answer("Сохранено")

@dp.callback_query(F.data == "draft_cancel")
async def cb_draft_cancel(callback: CallbackQuery):
    user_state.pop(callback.from_user.id, None)
    await callback.message.edit_text(
        "❌ Черновик отменён. Ничего не сохранено.",
        reply_markup=main_menu(callback.from_user.id)
    )
    await callback.answer("Отменено")

# ============ ГЛАВНОЕ МЕНЮ ============
@dp.callback_query(F.data == "main_menu")
async def cb_main_menu(callback: CallbackQuery):
    user_state.pop(callback.from_user.id, None)
    await callback.message.edit_text(
        "🏠 **Главное меню**",
        parse_mode="Markdown",
        reply_markup=main_menu(callback.from_user.id)
    )
    await callback.answer()

@dp.callback_query(F.data == "noop")
async def cb_noop(callback: CallbackQuery):
    await callback.answer()

# ============ ПО ДАТАМ ============
@dp.callback_query(F.data == "by_date")
async def cb_by_date(callback: CallbackQuery):
    user_state.pop(callback.from_user.id, None)
    await callback.message.edit_text(
        "📅 **Выбери период:**",
        parse_mode="Markdown",
        reply_markup=date_filter_menu()
    )
    await callback.answer()

@dp.callback_query(F.data == "date_custom")
async def cb_date_custom(callback: CallbackQuery):
    user_state[callback.from_user.id] = {"action": "await_custom_date"}
    await callback.message.edit_text(
        "🗓 **Свой период**\n\n"
        "Отправь одну или две даты в формате **ДД.ММ.ГГГГ**.\n"
        "Примеры:\n"
        "`21.09.2026` — за один день\n"
        "`01.09.2026 15.09.2026` — диапазон\n"
        "`21.09` — текущий год",
        parse_mode="Markdown",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="❌ Отмена", callback_data="by_date")],
        ])
    )
    await callback.answer()

@dp.callback_query(F.data.startswith("date_"))
async def cb_date_chosen(callback: CallbackQuery):
    if callback.data == "date_custom":
        return
    parts = callback.data.split("_")
    period = parts[1]
    page = int(parts[2])
    if period not in DATE_FILTERS:
        await callback.answer("Неизвестный период", show_alert=True)
        return
    await show_page(callback.message, f"date_{period}", page, edit=True)
    await callback.answer()

# ============ РЕДАКТИРОВАНИЕ ============
@dp.callback_query(F.data.startswith("edit_"))
async def cb_edit_request(callback: CallbackQuery):
    parts = callback.data.split("_")
    note_id = int(parts[1])
    page = int(parts[-1])
    prefix = "_".join(parts[2:-1])
    note = get_note(note_id)
    if not note:
        await callback.answer("Запись уже удалена.", show_alert=True)
        return
    is_owner = note.user_id == callback.from_user.id
    if not (is_owner or is_admin(callback.from_user.id)):
        await callback.answer("⛔ Только свои записи.", show_alert=True)
        return
    user_state[callback.from_user.id] = {
        "action": "await_edit",
        "note_id": note_id,
        "prefix": prefix,
        "page": page,
    }
    cat_name = CATEGORIES.get(note.category, note.category or "—")
    current = note.text if note.text else "_(пусто)_"
    await callback.message.answer(
        f"✏️ **Редактирование #{note_id}**\n\n"
        f"🗂 {cat_name}\n👤 {note.author_name}\n"
        f"🕒 {note.created_at.strftime('%d.%m.%Y %H:%M')}\n\n"
        f"📝 Текущий текст:\n{current}\n\n"
        "Отправь **новый текст** одним сообщением.",
        parse_mode="Markdown",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="❌ Отмена", callback_data=f"editcancel_{prefix}_{page}")]
        ])
    )
    await callback.answer()

@dp.callback_query(F.data.startswith("editcancel_"))
async def cb_edit_cancel(callback: CallbackQuery):
    parts = callback.data.split("_")
    page = int(parts[-1])
    prefix = "_".join(parts[1:-1])
    user_state.pop(callback.from_user.id, None)
    await callback.message.edit_text("❌ Редактирование отменено.")
    await show_page(callback.message, prefix, page, edit=False)
    await callback.answer()

# ============ УДАЛЕНИЕ ============
@dp.callback_query(F.data.startswith("del_"))
async def cb_delete_request(callback: CallbackQuery):
    parts = callback.data.split("_")
    note_id = int(parts[1])
    page = int(parts[-1])
    prefix = "_".join(parts[2:-1])
    note = get_note(note_id)
    if not note:
        await callback.answer("Запись уже удалена.", show_alert=True)
        return
    is_owner = note.user_id == callback.from_user.id
    if not (is_owner or is_admin(callback.from_user.id)):
        await callback.answer("⛔ Только свои записи.", show_alert=True)
        return
    cat_name = CATEGORIES.get(note.category, note.category or "—")
    preview = (note.text or "")[:200]
    if len(note.text or "") > 200:
        preview += "..."
    text = (
        f"⚠️ **Удалить запись #{note.id}?**\n\n"
        f"🗂 {cat_name}\n👤 {note.author_name}\n"
        f"🕒 {note.created_at.strftime('%d.%m.%Y %H:%M')}"
    )
    if preview:
        text += f"\n\n📝 {preview}"
    kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="✅ Да, удалить", callback_data=f"delok_{note_id}_{prefix}_{page}")],
        [InlineKeyboardButton(text="❌ Отмена", callback_data=f"{prefix}_page_{page}")],
    ])
    await callback.message.answer(text, parse_mode="Markdown", reply_markup=kb)
    await callback.answer()

@dp.callback_query(F.data.startswith("delok_"))
async def cb_delete_confirm(callback: CallbackQuery):
    parts = callback.data.split("_")
    note_id = int(parts[1])
    page = int(parts[-1])
    prefix = "_".join(parts[2:-1])
    note = get_note(note_id)
    if not note:
        await callback.answer("Запись уже удалена.", show_alert=True)
        return
    is_owner = note.user_id == callback.from_user.id
    if not (is_owner or is_admin(callback.from_user.id)):
        await callback.answer("⛔ Недостаточно прав.", show_alert=True)
        return
    delete_note(note_id)
    await callback.message.edit_text(f"🗑 Запись #{note_id} удалена.")
    await callback.answer("Удалено")
    await show_page(callback.message, prefix, page, edit=False)

# ============ ПОКАЗ СТРАНИЦЫ ============
async def show_page(target_message: Message, prefix: str, page: int, edit: bool = True):
    user_id_filter = None
    category_filter = None
    since = None
    until = None
    export_cb = None
    title = ""

    if prefix == "myall":
        title = "📖 **Все мои записи**"
        export_cb = "export_my"
        user_id_filter = target_message.chat.id
    elif prefix.startswith("mycat_"):
        key = prefix.replace("mycat_", "")
        category_filter = key
        title = f"📖 **{CATEGORIES.get(key, key)}**"
        export_cb = f"export_my_{key}"
        user_id_filter = target_message.chat.id
    elif prefix == "all":
        title = "📊 **Все записи сотрудников**"
        export_cb = "export_all"
    elif prefix.startswith("author_"):
        uid = int(prefix.replace("author_", ""))
        user_id_filter = uid
        title = "📋 **Записи сотрудника**"
        export_cb = f"export_author_{uid}"
    elif prefix.startswith("catpage_"):
        key = prefix.replace("catpage_", "")
        category_filter = key
        title = f"🗂 **{CATEGORIES.get(key, key)}**"
        export_cb = f"export_cat_{key}"
    elif prefix.startswith("date_"):
        period = prefix.replace("date_", "")
        if period not in DATE_FILTERS:
            return
        since = date_range_start(period)
        until = date_range_end(period)
        title = f"📅 **{DATE_FILTERS[period]}**"
        export_cb = f"export_date_{period}"
        if not is_admin(target_message.chat.id):
            user_id_filter = target_message.chat.id
    elif prefix.startswith("range_"):
        parts = prefix.split("_")
        try:
            d1 = datetime.strptime(parts[1], "%Y%m%d")
            d2 = datetime.strptime(parts[2], "%Y%m%d")
        except Exception:
            return
        since = d1
        until = d2 + timedelta(days=1)
        title = f"🗓 **{d1.strftime('%d.%m.%Y')} — {d2.strftime('%d.%m.%Y')}**"
        export_cb = f"export_range_{parts[1]}_{parts[2]}"
        if not is_admin(target_message.chat.id):
            user_id_filter = target_message.chat.id

    total = count_notes(user_id=user_id_filter, category=category_filter,
                        since=since, until=until)
    total_pages = max(1, (total + PAGE_SIZE - 1) // PAGE_SIZE)
    if page >= total_pages:
        page = total_pages - 1
    notes = get_notes_page(user_id=user_id_filter, category=category_filter,
                           since=since, until=until, offset=page * PAGE_SIZE)

    if not notes:
        text = f"{title}\n\n_Записей нет._"
        kb = InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="📅 Другой период", callback_data="by_date")],
            [InlineKeyboardButton(text="⬅️ В меню", callback_data="main_menu")],
        ])
    else:
        text = f"{title} (стр. {page+1}/{total_pages}, всего {total})\n\n"
        text += format_notes(notes)
        kb = pagination_kb(prefix, page, total_pages, notes=notes, export_cb=export_cb)

    if edit:
        try:
            await target_message.edit_text(text, parse_mode="Markdown", reply_markup=kb)
        except Exception:
            await target_message.answer(text, parse_mode="Markdown", reply_markup=kb)
    else:
        await target_message.answer(text, parse_mode="Markdown", reply_markup=kb)

    if notes:
        await send_attachments(target_message, notes)

# ============ МОИ ЗАПИСИ ============
@dp.callback_query(F.data == "my_notes")
async def cb_my_notes(callback: CallbackQuery):
    counts = count_by_category(user_id=callback.from_user.id)
    if not counts:
        await callback.message.answer("У тебя пока нет записей.", reply_markup=back_menu())
        await callback.answer()
        return
    buttons = []
    for key, name in CATEGORIES.items():
        c = counts.get(key, 0)
        buttons.append([InlineKeyboardButton(text=f"{name} ({c})", callback_data=f"mycat_{key}_0")])
    buttons.append([InlineKeyboardButton(text="📋 Все мои записи", callback_data="myall_page_0")])
    buttons.append([InlineKeyboardButton(text="📅 По датам", callback_data="by_date")])
    buttons.append([InlineKeyboardButton(text="⬅️ В меню", callback_data="main_menu")])
    await callback.message.edit_text(
        "📖 **Мои записи по категориям:**",
        parse_mode="Markdown",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=buttons)
    )
    await callback.answer()

@dp.callback_query(F.data.startswith("myall_page_"))
async def cb_myall_page(callback: CallbackQuery):
    page = int(callback.data.split("_")[-1])
    await show_page(callback.message, "myall", page, edit=True)
    await
