import asyncio
import logging
import csv
import io
from datetime import datetime, timedelta
from aiogram import Bot, Dispatcher, F
from aiogram.filters import Command
from aiogram.types import (
    Message, InlineKeyboardMarkup, InlineKeyboardButton,
    CallbackQuery, BufferedInputFile
)
from sqlalchemy import create_engine, Column, Integer, String, DateTime, BigInteger, select, func
from sqlalchemy.orm import DeclarativeBase, Session

# ============ НАСТРОЙКИ ============
BOT_TOKEN = "8365458785:AAHyVIla42H9kRKG0oT8SQvjiOFiWjOeTSE"

ADMIN_IDS = [
    1170348114,   # <-- ЗАМЕНИТЕ на ваш ID
    # 987654321, # <-- ID второго наблюдателя
]

PAGE_SIZE = 10

logging.basicConfig(level=logging.INFO)

# ============ КАТЕГОРИИ ============
CATEGORIES = {
    "raw": " Исходное сырьё",
    "analysis": " Анализ",
    "mech": " Механоактивация",
    "forming": " Формование",
}

# ============ ПЕРИОДЫ ДЛЯ ФИЛЬТРА ============
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

def save_note(user_id: int, category: str, text: str = None,
              photo_id: str = None, document_id: str = None, document_name: str = None):
    user = get_user(user_id)
    author = user.full_name if user else f"ID:{user_id}"
    with Session(engine) as session:
        session.add(Note(
            user_id=user_id, author_name=author, category=category,
            text=text, photo_id=photo_id,
            document_id=document_id, document_name=document_name
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

# ---- Период -> диапазон дат ----
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
    return None  # all

def date_range_end(period: str):
    if period == "yday":
        now = datetime.now()
        return now.replace(hour=0, minute=0, second=0, microsecond=0)
    return None

def parse_user_date(s: str):
    """Парсит ДД.ММ.ГГГГ или ДД.ММ. Возвращает datetime или None.
    Если год не указан — текущий."""
    s = s.strip()
    formats = ["%d.%m.%Y", "%d.%m.%y", "%d.%m"]
    for fmt in formats:
        try:
            dt = datetime.strptime(s, fmt)
            if fmt == "%d.%m":
                dt = dt.replace(year=datetime.now().year)
            return dt
        except ValueError:
            continue
    return None

def count_notes(user_id: int = None, category: str = None,
                since: datetime = None, until: datetime = None) -> int:
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

def get_notes_page(user_id: int = None, category: str = None,
                   since: datetime = None, until: datetime = None,
                   offset: int = 0, limit: int = PAGE_SIZE):
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

def get_all_notes_for_export(user_id: int = None, category: str = None,
                             since: datetime = None, until: datetime = None):
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

def count_by_category(user_id: int = None):
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

# ============ CSV ЭКСПОРТ ============
def build_csv(user_id: int = None, category: str = None,
              since: datetime = None, until: datetime = None) -> BufferedInputFile:
    notes = get_all_notes_for_export(user_id=user_id, category=category,
                                     since=since, until=until)
    buf = io.StringIO()
    writer = csv.writer(buf, delimiter=";")
    writer.writerow(["ID", "Дата", "Изменено", "Автор", "Категория", "Текст",
                     "Фото (file_id)", "Документ", "Документ (file_id)"])
    for n in notes:
        writer.writerow([
            n.id,
            n.created_at.strftime("%d.%m.%Y %H:%M"),
            n.updated_at.strftime("%d.%m.%Y %H:%M") if n.updated_at else "",
            n.author_name,
            CATEGORIES.get(n.category, n.category or ""),
            (n.text or "").replace("\n", " "),
            n.photo_id or "",
            n.document_name or "",
            n.document_id or ""
        ])
    data = buf.getvalue().encode("utf-8-sig")
    filename = f"notes_{datetime.now().strftime('%Y%m%d_%H%M')}.csv"
    return BufferedInputFile(data, filename=filename)

# ============ КЛАВИАТУРЫ ============
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

def date_filter_menu():
    buttons = [[InlineKeyboardButton(text=name, callback_data=f"date_{key}_0")]
               for key, name in DATE_FILTERS.items()]
    buttons.append([InlineKeyboardButton(text="🗓 Свой период", callback_data="date_custom")])
    buttons.append([InlineKeyboardButton(text="⬅️ В меню", callback_data="main_menu")])
    return InlineKeyboardMarkup(inline_keyboard=buttons)

def pagination_kb(prefix: str, page: int, total_pages: int,
                  notes=None, export_cb: str = None):
    rows = []
    if notes:
        for n in notes:
            rows.append([
                InlineKeyboardButton(text=f"✏️ Изменить #{n.id}", callback_data=f"edit_{n.id}_{prefix}_{page}"),
                InlineKeyboardButton(text=f"🗑 Удалить #{n.id}", callback_data=f"del_{n.id}_{prefix}_{page}"),
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

# ============ КОМАНДЫ ============
@dp.message(Command("start"))
async def cmd_start(message: Message):
    user_state.pop(message.from_user.id, None)
    user = get_user(message.from_user.id)
    if not user:
        await message.answer(
            "👋 Добро пожаловать в лабораторный журнал!\n\n"
            "Сначала зарегистрируйтесь:\n"
            "`/register Имя Фамилия`",
            parse_mode="Markdown"
        )
        return
    await message.answer(
        f"👋 Привет, {user.full_name}!\n\nВыбери действие:",
        reply_markup=main_menu(message.from_user.id)
    )

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
        reply_markup=main_menu(message.from_user.id)
    )

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
    user_state[callback.from_user.id] = {"action": "await_content", "category": key}
    await callback.message.edit_text(
        f"Категория: **{CATEGORIES[key]}**\n\n"
        "✍️ Теперь отправь текст, фото или документ.\n"
        "Можно прикрепить подпись к фото/документу — она сохранится как текст записи.",
        parse_mode="Markdown"
    )
    await callback.answer()

# ============ ГЛАВНОЕ МЕНЮ ============
@dp.callback_query(F.data == "main_menu")
async def cb_main_menu(callback: CallbackQuery):
    user_state.pop(callback.from_user.id, None)
    await callback.message.edit_text(
        "Главное меню:",
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

@dp.callback_query(F.data.startswith("date_"))
async def cb_date_chosen(callback: CallbackQuery):
    # Отдельно обрабатываем «Свой период»
    if callback.data == "date_custom":
        user_state[callback.from_user.id] = {"action": "await_custom_date"}
        await callback.message.edit_text(
            "🗓 **Свой период**\n\n"
            "Отправь одну или две даты в формате **ДД.ММ.ГГГГ**.\n\n"
            "• Одна дата — покажет записи за этот день.\n"
            "• Две даты через пробел или дефис — диапазон.\n\n"
            "Примеры:\n"
            "`21.09.2026` — за 21 сентября 2026\n"
            "`01.09.2026 15.09.2026` — с 1 по 15 сентября\n"
            "`01.09.2026 - 15.09.2026` — то же самое\n"
            "`21.09` — за 21 сентября текущего года",
            parse_mode="Markdown",
            reply_markup=InlineKeyboardMarkup(inline_keyboard=[
                [InlineKeyboardButton(text="❌ Отмена", callback_data="by_date")],
            ])
        )
        await callback.answer()
        return

    # формат: date_{period}_{page}
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
        await callback.answer("⛔ Ты можешь редактировать только свои записи.", show_alert=True)
        return

    user_state[callback.from_user.id] = {
        "action": "await_edit",
        "note_id": note_id,
        "prefix": prefix,
        "page": page
    }

    cat_name = CATEGORIES.get(note.category, note.category or "—")
    current_text = note.text if note.text else "_(пусто)_"
    await callback.message.answer(
        f"✏️ **Редактирование записи #{note_id}**\n\n"
        f"🗂 {cat_name}\n"
        f"👤 {note.author_name}\n"
        f"🕒 {note.created_at.strftime('%d.%m.%Y %H:%M')}\n\n"
        f"📝 Текущий текст:\n{current_text}\n\n"
        f"Отправь **новый текст** одним сообщением.\n"
        f"Чтобы отменить — нажми кнопку ниже.",
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
        await callback.answer("⛔ Ты можешь удалять только свои записи.", show_alert=True)
        return

    cat_name = CATEGORIES.get(note.category, note.category or "—")
    preview = (note.text or "")[:200]
    if len(note.text or "") > 200:
        preview += "..."
    text = (
        f"⚠️ **Удалить запись #{note.id}?**\n\n"
        f"🗂 {cat_name}\n"
        f"👤 {note.author_name}\n"
        f"🕒 {note.created_at.strftime('%d.%m.%Y %H:%M')}"
    )
    if preview:
        text += f"\n\n📝 {preview}"
    if note.photo_id:
        text += "\n📷 есть фото"
    if note.document_id:
        text += f"\n📎 {note.document_name or 'документ'}"

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
    """prefix может быть:
    myall, mycat_<key>, all, author_<uid>, catpage_<key>, date_<period>,
    range_<YYYYMMDD>_<YYYYMMDD>
    """
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
        # range_YYYYMMDD_YYYYMMDD
        parts = prefix.split("_")
        try:
            d1 = datetime.strptime(parts[1], "%Y%m%d")
            d2 = datetime.strptime(parts[2], "%Y%m%d")
        except Exception:
            return
        since = d1
        until = d2 + timedelta(days=1)  # включая конечный день
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
                           since=since, until=until,
                           offset=page * PAGE_SIZE)

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
    await callback.answer()

@dp.callback_query(F.data.startswith("mycat_"))
async def cb_mycat_page(callback: CallbackQuery):
    parts = callback.data.split("_")
    key = parts[1]
    page = int(parts[2])
    await show_page(callback.message, f"mycat_{key}", page, edit=True)
    await callback.answer()

# ============ АДМИН: ВСЕ ЗАПИСИ ============
@dp.callback_query(F.data.startswith("all_notes_"))
async def cb_all_notes(callback: CallbackQuery):
    if not is_admin(callback.from_user.id):
        await callback.answer("⛔ Только для наблюдателей.", show_alert=True)
        return
    page = int(callback.data.split("_")[-1])
    await show_page(callback.message, "all", page, edit=True)
    await callback.answer()

@dp.callback_query(F.data.startswith("all_page_"))
async def cb_all_page(callback: CallbackQuery):
    if not is_admin(callback.from_user.id):
        await callback.answer("⛔ Доступ запрещён.", show_alert=True)
        return
    page = int(callback.data.split("_")[-1])
    await show_page(callback.message, "all", page, edit=True)
    await callback.answer()

# ============ АДМИН: ПО СОТРУДНИКАМ ============
@dp.callback_query(F.data == "by_author")
async def cb_by_author(callback: CallbackQuery):
    if not is_admin(callback.from_user.id):
        await callback.answer("⛔ Только для наблюдателей.", show_alert=True)
        return
    authors = get_all_authors()
    if not authors:
        await callback.message.answer("Пока нет записей.", reply_markup=back_menu())
        await callback.answer()
        return
    buttons = [[InlineKeyboardButton(text=f"{name} ({c})", callback_data=f"author_{uid}_0")]
               for uid, name, c in authors]
    buttons.append([InlineKeyboardButton(text="⬅️ В меню", callback_data="main_menu")])
    await callback.message.edit_text(
        "👥 **Выбери сотрудника:**",
        parse_mode="Markdown",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=buttons)
    )
    await callback.answer()

@dp.callback_query(F.data.startswith("author_"))
async def cb_author_notes(callback: CallbackQuery):
    if not is_admin(callback.from_user.id):
        await callback.answer("⛔ Доступ запрещён.", show_alert=True)
        return
    parts = callback.data.split("_")
    uid = int(parts[1])
    page = int(parts[2])
    await show_page(callback.message, f"author_{uid}", page, edit=True)
    await callback.answer()

# ============ АДМИН: ПО КАТЕГОРИЯМ ============
@dp.callback_query(F.data == "by_category")
async def cb_by_category(callback: CallbackQuery):
    if not is_admin(callback.from_user.id):
        await callback.answer("⛔ Только для наблюдателей.", show_alert=True)
        return
    counts = count_by_category()
    if not counts:
        await callback.message.answer("Записей нет.", reply_markup=back_menu())
        await callback.answer()
        return
    buttons = []
    for key, name in CATEGORIES.items():
        c = counts.get(key, 0)
        buttons.append([InlineKeyboardButton(text=f"{name} ({c})", callback_data=f"catpage_{key}_0")])
    buttons.append([InlineKeyboardButton(text="⬅️ В меню", callback_data="main_menu")])
    await callback.message.edit_text(
        "🗂 **Записи по категориям:**",
        parse_mode="Markdown",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=buttons)
    )
    await callback.answer()

@dp.callback_query(F.data.startswith("catpage_"))
async def cb_catpage(callback: CallbackQuery):
    if not is_admin(callback.from_user.id):
        await callback.answer("⛔ Доступ запрещён.", show_alert=True)
        return
    parts = callback.data.split("_")
    key = parts[1]
    page = int(parts[2])
    await show_page(callback.message, f"catpage_{key}", page, edit=True)
    await callback.answer()

# ============ ЭКСПОРТ CSV ============
@dp.callback_query(F.data == "export_all")
async def cb_export_all(callback: CallbackQuery):
    if not is_admin(callback.from_user.id):
        await callback.answer("⛔ Только для наблюдателей.", show_alert=True)
        return
    await callback.answer("Готовлю файл...")
    await callback.message.answer_document(build_csv(), caption="📥 Все записи (CSV)")

@dp.callback_query(F.data == "export_my")
async def cb_export_my(callback: CallbackQuery):
    await callback.answer("Готовлю файл...")
    await callback.message.answer_document(
        build_csv(user_id=callback.from_user.id), caption="📥 Мои записи (CSV)")

@dp.callback_query(F.data.startswith("export_my_"))
async def cb_export_my_cat(callback: CallbackQuery):
    key = callback.data.replace("export_my_", "")
    await callback.answer("Готовлю файл...")
    await callback.message.answer_document(
        build_csv(user_id=callback.from_user.id, category=key),
        caption=f"📥 {CATEGORIES.get(key, key)} (CSV)")

@dp.callback_query(F.data.startswith("export_cat_"))
async def cb_export_cat(callback: CallbackQuery):
    if not is_admin(callback.from_user.id):
        await callback.answer("⛔ Доступ запрещён.", show_alert=True)
        return
    key = callback.data.replace("export_cat_", "")
    await callback.answer("Готовлю файл...")
    await callback.message.answer_document(
        build_csv(category=key), caption=f"📥 {CATEGORIES.get(key, key)} (CSV)")

@dp.callback_query(F.data.startswith("export_author_"))
async def cb_export_author(callback: CallbackQuery):
    if not is_admin(callback.from_user.id):
        await callback.answer("⛔ Доступ запрещён.", show_alert=True)
        return
    uid = int(callback.data.replace("export_author_", ""))
    await callback.answer("Готовлю файл...")
    await callback.message.answer_document(
        build_csv(user_id=uid), caption="📥 Записи сотрудника (CSV)")

@dp.callback_query(F.data.startswith("export_date_"))
async def cb_export_date(callback: CallbackQuery):
    period = callback.data.replace("export_date_", "")
    if period not in DATE_FILTERS:
        await callback.answer("Неизвестный период", show_alert=True)
        return
    since = date_range_start(period)
    until = date_range_end(period)
    user_filter = None
    if not is_admin(callback.from_user.id):
        user_filter = callback.from_user.id
    await callback.answer("Готовлю файл...")
    await callback.message.answer_document(
        build_csv(user_id=user_filter, since=since, until=until),
        caption=f"📥 {DATE_FILTERS[period]} (CSV)")

@dp.callback_query(F.data.startswith("export_range_"))
async def cb_export_range(callback: CallbackQuery):
    parts = callback.data.split("_")
    if len(parts) < 4:
        await callback.answer("Ошибка", show_alert=True)
        return
    try:
        d1 = datetime.strptime(parts[2], "%Y%m%d")
        d2 = datetime.strptime(parts[3], "%Y%m%d")
    except Exception:
        await callback.answer("Ошибка дат", show_alert=True)
        return
    since = d1
    until = d2 + timedelta(days=1)
    user_filter = None
    if not is_admin(callback.from_user.id):
        user_filter = callback.from_user.id
    await callback.answer("Готовлю файл...")
    await callback.message.answer_document(
        build_csv(user_id=user_filter, since=since, until=until),
        caption=f"📥 {d1.strftime('%d.%m.%Y')} — {d2.strftime('%d.%m.%Y')} (CSV)")

# ============ ОЧИСТКА ============
@dp.callback_query(F.data == "clear_my")
async def cb_clear_my(callback: CallbackQuery):
    clear_user_notes(callback.from_user.id)
    await callback.message.answer("🗑 Все твои записи удалены.", reply_markup=back_menu())
    await callback.answer()

# ============ ФОРМАТИРОВАНИЕ ============
def format_notes(notes) -> str:
    lines = []
    for i, n in enumerate(notes, 1):
        cat_name = CATEGORIES.get(n.category, n.category or "—")
        line = (f"{i}. 🆔 #{n.id}\n"
                f"   🗂 {cat_name}\n"
                f"   👤 {n.author_name}\n"
                f"   🕒 {n.created_at.strftime('%d.%m.%Y %H:%M')}")
        if n.updated_at:
            line += f" (изм. {n.updated_at.strftime('%d.%m %H:%M')})"
        if n.text:
            txt = n.text[:300] + ("..." if len(n.text) > 300 else "")
            line += f"\n   📝 {txt}"
        if n.photo_id:
            line += "\n   📷 (фото)"
        if n.document_id:
            line += f"\n   📎 {n.document_name or 'документ'}"
        lines.append(line)
    return "\n\n".join(lines)

async def send_attachments(target_message: Message, notes):
    for n in notes:
        cat_name = CATEGORIES.get(n.category, n.category or "—")
        caption_header = (
            f"🗂 {cat_name}\n"
            f"👤 {n.author_name}\n"
            f"🕒 {n.created_at.strftime('%d.%m.%Y %H:%M')}"
        )
        if n.updated_at:
            caption_header += f"\n✏️ изменено {n.updated_at.strftime('%d.%m.%Y %H:%M')}"
        if n.photo_id:
            caption = caption_header
            if n.text:
                caption += f"\n\n{n.text}"
            try:
                await target_message.answer_photo(photo=n.photo_id, caption=caption[:1024])
            except Exception as e:
                logging.warning(f"Не удалось отправить фото #{n.id}: {e}")
        if n.document_id:
            doc_caption = caption_header
            if n.document_name:
                doc_caption += f"\n📎 {n.document_name}"
            try:
                await target_message.answer_document(
                    document=n.document_id, caption=doc_caption[:1024]
                )
            except Exception as e:
                logging.warning(f"Не удалось отправить документ #{n.id}: {e}")

# ============ ПРИЁМ КОНТЕНТА ============
@dp.message(F.photo)
async def handle_photo(message: Message):
    state = user_state.get(message.from_user.id)
    if not state or state.get("action") != "await_content":
        await message.answer(
            "⚠️ Сначала нажми «📝 Новая запись» и выбери категорию.",
            reply_markup=main_menu(message.from_user.id)
        )
        return
    category = state["category"]
    photo_id = message.photo[-1].file_id
    save_note(message.from_user.id, category=category,
              text=message.caption, photo_id=photo_id)
    user_state.pop(message.from_user.id, None)
    await message.answer(
        f"✅ Запись сохранена в категорию **{CATEGORIES[category]}**.",
        parse_mode="Markdown",
        reply_markup=main_menu(message.from_user.id)
    )

@dp.message(F.document)
async def handle_document(message: Message):
    state = user_state.get(message.from_user.id)
    if not state or state.get("action") != "await_content":
        await message.answer(
            "⚠️ Сначала нажми «📝 Новая запись» и выбери категорию.",
            reply_markup=main_menu(message.from_user.id)
        )
        return
    category = state["category"]
    document_id = message.document.file_id
    document_name = message.document.file_name or "файл"
    save_note(message.from_user.id, category=category,
              text=message.caption,
              document_id=document_id, document_name=document_name)
    user_state.pop(message.from_user.id, None)
    await message.answer(
        f"✅ Документ сохранён в категорию **{CATEGORIES[category]}**.\n"
        f"📎 {document_name}",
        parse_mode="Markdown",
        reply_markup=main_menu(message.from_user.id)
    )

@dp.message(F.text)
async def handle_text(message: Message):
    if message.text.startswith("/"):
        return

    state = user_state.get(message.from_user.id)

    # ---- Ручной ввод дат ----
    if state and state.get("action") == "await_custom_date":
        text = message.text.strip()
        # Разделители: пробел, дефис, тире, "по"
        raw = text.replace(" - ", " ").replace(" по ", " ").replace("-", " ").replace("—", " ")
        parts = [p for p in raw.split() if p]
        if len(parts) == 1:
            d1 = parse_user_date(parts[0])
            if not d1:
                await message.answer(
                    "❌ Не удалось разобрать дату. Пример: `21.09.2026` или `01.09.2026 15.09.2026`",
                    parse_mode="Markdown"
                )
                return
            d1 = d1.replace(hour=0, minute=0, second=0, microsecond=0)
            d2 = d1
        elif len(parts) == 2:
            d1 = parse_user_date(parts[0])
            d2 = parse_user_date(parts[1])
            if not d1 or not d2:
                await message.answer(
                    "❌ Не удалось разобрать даты. Пример: `01.09.2026 15.09.2026`",
                    parse_mode="Markdown"
                )
                return
            d1 = d1.replace(hour=0, minute=0, second=0, microsecond=0)
            d2 = d2.replace(hour=0, minute=0, second=0, microsecond=0)
            if d1 > d2:
                d1, d2 = d2, d1
        else:
            await message.answer(
                "❌ Слишком много дат. Отправь одну или две даты.",
                reply_markup=back_menu()
            )
            return

        user_state.pop(message.from_user.id, None)
        prefix = f"range_{d1.strftime('%Y%m%d')}_{d2.strftime('%Y%m%d')}"
        # Показываем результаты
        await show_page(message, prefix, 0, edit=False)
        return

    # ---- Режим редактирования ----
    if state and state.get("action") == "await_edit":
        note_id = state["note_id"]
        prefix = state["prefix"]
        page = state["page"]
        update_note_text(note_id, message.text)
        user_state.pop(message.from_user.id, None)
        await message.answer(f"✅ Запись #{note_id} обновлена.")
        await show_page(message, prefix, page, edit=False)
        return

    # ---- Обычный режим — новая запись ----
    if not state or state.get("action") != "await_content":
        await message.answer(
            "⚠️ Сначала нажми «📝 Новая запись» и выбери категорию.",
            reply_markup=main_menu(message.from_user.id)
        )
        return
    category = state["category"]
    save_note(message.from_user.id, category=category, text=message.text)
    user_state.pop(message.from_user.id, None)
    await message.answer(
        f"✅ Запись сохранена в категорию **{CATEGORIES[category]}**.",
        parse_mode="Markdown",
        reply_markup=main_menu(message.from_user.id)
    )

# ============ ЗАПУСК ============
async def main():
    print("Бот запущен...")
    await dp.start_polling(bot)

if __name__ == "__main__":
    asyncio.run(main())
