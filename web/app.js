"use strict";

/* =====================================================================
   Tablero comercial EcoBottle AR
   Lee las tablas mart de data/marts/ (calculadas en sql/05_marts.sql),
   busca la fila que corresponde a los filtros y la dibuja.
   No suma, no promedia ni divide valores de negocio.
   ===================================================================== */

const RUTA = "data/marts/";
const ARCHIVOS = {
  ventas: "mart_sales_kpi",
  estados: "mart_order_status",
  productos: "mart_sales_product",
  clientes: "mart_customer_kpi",
  sesiones: "mart_session_mix",
  nps: "mart_nps_kpi",
  npsGrupos: "mart_nps_group",
  entregas: "mart_delivery_kpi",
  pagos: "mart_payment_kpi",
  crecimiento: "mart_growth",
  lideres: "mart_product_leaders",
  periodos: "mart_dim_period",
  canales: "mart_dim_channel",
  provincias: "mart_dim_province",
};

const COLOR = (nombre) => getComputedStyle(document.documentElement).getPropertyValue(nombre).trim();
const CANAL_COLOR = { ONLINE: "--online", OFFLINE: "--offline" };
const CANAL_NOMBRE = { ONLINE: "Tienda online", OFFLINE: "Tiendas físicas", Todos: "Todos" };
const PROD_COLOR = ["--prod-1", "--prod-2"];
const NPS_COLOR = { Promotor: "--promotor", Pasivo: "--pasivo", Detractor: "--detractor" };
const FRANJA = ["2024-07", "2024-08"];

/* ---------------------------------------------------------------------
   Lectura de CSV
   --------------------------------------------------------------------- */
function parseCSV(texto) {
  const filas = [];
  let fila = [], campo = "", comillas = false;
  for (let i = 0; i < texto.length; i++) {
    const ch = texto[i];
    if (comillas) {
      if (ch === '"' && texto[i + 1] === '"') { campo += '"'; i++; }
      else if (ch === '"') comillas = false;
      else campo += ch;
    } else if (ch === '"') comillas = true;
    else if (ch === ",") { fila.push(campo); campo = ""; }
    else if (ch === "\n" || ch === "\r") {
      if (ch === "\r" && texto[i + 1] === "\n") i++;
      fila.push(campo); campo = "";
      if (fila.length > 1 || fila[0] !== "") filas.push(fila);
      fila = [];
    } else campo += ch;
  }
  if (campo !== "" || fila.length) { fila.push(campo); filas.push(fila); }
  const [cab, ...resto] = filas;
  return resto.map((f) => Object.fromEntries(cab.map((c, i) => [c, f[i] ?? ""])));
}

const num = (v) => (v === "" || v == null ? null : Number(v));

async function cargar() {
  const entradas = await Promise.all(Object.entries(ARCHIVOS).map(async ([clave, archivo]) => {
    const resp = await fetch(`${RUTA}${archivo}.csv`);
    if (!resp.ok) throw new Error(`No se pudo leer ${archivo}.csv (${resp.status})`);
    return [clave, parseCSV(await resp.text())];
  }));
  return Object.fromEntries(entradas);
}

/* ---------------------------------------------------------------------
   Índices: clave de búsqueda -> fila del mart
   --------------------------------------------------------------------- */
const D = {};
const k = (...partes) => partes.join("|");
const agrupar = (filas, claveDe) => {
  const m = new Map();
  for (const f of filas) {
    const c = claveDe(f);
    if (!m.has(c)) m.set(c, []);
    m.get(c).push(f);
  }
  return m;
};

function indexar(t) {
  D.ventas = new Map(t.ventas.map((f) => [k(f.period, f.channel, f.province), f]));
  D.estados = agrupar(t.estados, (f) => k(f.period, f.channel, f.province));
  D.productos = agrupar(t.productos, (f) => k(f.period, f.channel, f.province));
  D.clientes = new Map(t.clientes.map((f) => [f.period, f]));
  D.sesiones = agrupar(t.sesiones, (f) => k(f.period, f.breakdown));
  D.nps = new Map(t.nps.map((f) => [k(f.period, f.channel), f]));
  D.npsGrupos = agrupar(t.npsGrupos, (f) => k(f.period, f.channel));
  D.entregas = new Map(t.entregas.map((f) => [k(f.period, f.channel, f.province), f]));
  D.pagos = agrupar(t.pagos.filter((f) => f.payment_method !== "Todos"), (f) => k(f.period, f.channel));
  D.lideres = t.lideres;
  D.crecimiento = t.crecimiento.slice().sort((a, b) => num(a.sort_order) - num(b.sort_order));
  D.periodos = t.periodos.slice().sort((a, b) => num(a.sort_order) - num(b.sort_order));
  D.meses = D.periodos.filter((p) => p.period_type === "month");
  D.etiqueta = new Map(D.periodos.map((p) => [p.period, p.period_label]));
  D.canales = t.canales.slice().sort((a, b) => num(a.sort_order) - num(b.sort_order));
  D.provincias = t.provincias.slice().sort((a, b) => num(a.sort_order) - num(b.sort_order));
  D.productosNombres = [...new Set(t.productos.map((f) => f.product))].sort();
}

/* ---------------------------------------------------------------------
   Estado de los filtros
   --------------------------------------------------------------------- */
const inicial = () => ({ anio: "Todo", mes: "", canal: "Todos", prov: "Todas", iva: "con" });
let F = inicial();
const prodOcultos = new Set();
const periodo = () => F.mes || F.anio;
const etiquetaPeriodo = () => D.etiqueta.get(periodo()) || periodo();

function mesesDelPeriodo() {
  if (F.mes) return new Set([F.mes]);
  if (F.anio !== "Todo") return new Set(D.meses.filter((m) => m.period.startsWith(F.anio)).map((m) => m.period));
  return null; // todo el período: ningún mes se atenúa
}

const filaVentas = (per, canal = F.canal, prov = F.prov) => D.ventas.get(k(per, canal, prov));
const ventasDe = (f) => (f ? num(F.iva === "con" ? f.sales_amount : f.sales_net_amount) : null);
const ticketDe = (f) => (f ? num(F.iva === "con" ? f.ticket_amount : f.ticket_net_amount) : null);

/* ---------------------------------------------------------------------
   Formatos (es-AR)
   --------------------------------------------------------------------- */
const fmt = (v, d = 0) => v.toLocaleString("es-AR", { minimumFractionDigits: d, maximumFractionDigits: d });
const nada = "—";
const pesosM = (v) => (v == null ? nada : `$${fmt(v / 1e6, 1)} M`);
const pesos = (v) => (v == null ? nada : `$${fmt(v)}`);
const entero = (v) => (v == null ? nada : fmt(v));
const pct = (v, d = 1) => (v == null ? nada : `${fmt(v * 100, d)} %`);
const dec1 = (v) => (v == null ? nada : fmt(v, 1));
const mesCorto = (ym) => {
  const [a, m] = ym.split("-");
  return `${["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"][Number(m) - 1]} ${a.slice(2)}`;
};
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

/* ---------------------------------------------------------------------
   Utilidades de SVG y tooltip
   --------------------------------------------------------------------- */
const NS = "http://www.w3.org/2000/svg";
function el(tag, attrs = {}, padre) {
  const n = document.createElementNS(NS, tag);
  for (const [a, v] of Object.entries(attrs)) if (v != null) n.setAttribute(a, v);
  if (padre) padre.appendChild(n);
  return n;
}
function lienzo(cont, alto) {
  cont.innerHTML = "";
  const ancho = Math.max(300, Math.round(cont.clientWidth || 600));
  const svg = el("svg", { viewBox: `0 0 ${ancho} ${alto}`, width: ancho, height: alto, role: "img" }, cont);
  return { svg, ancho, alto };
}
function escala(min, max, desde, hasta) {
  const d = max - min || 1;
  return (v) => desde + ((v - min) / d) * (hasta - desde);
}
function marcas(max, min = 0, n = 4) {
  const rango = max - min || 1;
  const paso0 = rango / n;
  const mag = 10 ** Math.floor(Math.log10(paso0));
  const paso = [1, 2, 2.5, 5, 10].map((f) => f * mag).find((p) => p >= paso0);
  const ini = Math.floor(min / paso) * paso;
  const fin = Math.ceil(max / paso) * paso;
  const ticks = [];
  for (let v = ini; v <= fin + paso / 2; v += paso) ticks.push(Math.round(v * 1e6) / 1e6);
  return ticks;
}
// Barra con extremo redondeado de 4px, anclada a la base
function barraV(padre, x, yTop, w, yBase, color, attrs = {}) {
  const h = Math.max(0, yBase - yTop);
  const r = Math.min(4, w / 2, h);
  const d = `M${x},${yBase} V${yTop + r} Q${x},${yTop} ${x + r},${yTop} H${x + w - r} Q${x + w},${yTop} ${x + w},${yTop + r} V${yBase} Z`;
  return el("path", { d, fill: color, ...attrs }, padre);
}
function barraH(padre, x0, y, xFin, h, color, attrs = {}) {
  const w = Math.max(0, xFin - x0);
  const r = Math.min(4, h / 2, w);
  const d = `M${x0},${y} H${x0 + w - r} Q${x0 + w},${y} ${x0 + w},${y + r} V${y + h - r} Q${x0 + w},${y + h} ${x0 + w - r},${y + h} H${x0} Z`;
  return el("path", { d, fill: color, ...attrs }, padre);
}

const tooltip = document.getElementById("tooltip");
function mostrarTip(html, evt) {
  tooltip.innerHTML = html;
  tooltip.hidden = false;
  const { innerWidth: W, innerHeight: H } = window;
  const r = tooltip.getBoundingClientRect();
  let x = evt.clientX + 14, y = evt.clientY + 14;
  if (x + r.width > W - 8) x = evt.clientX - r.width - 14;
  if (y + r.height > H - 8) y = evt.clientY - r.height - 14;
  tooltip.style.left = `${Math.max(8, x)}px`;
  tooltip.style.top = `${Math.max(8, y)}px`;
}
const ocultarTip = () => { tooltip.hidden = true; };
const filaTip = (color, texto) => `<span class="tt-fila"><i style="background:${color}"></i>${texto}</span>`;
function conTip(nodo, html) {
  nodo.addEventListener("mousemove", (e) => mostrarTip(typeof html === "function" ? html() : html, e));
  nodo.addEventListener("mouseleave", ocultarTip);
}

/* ---------------------------------------------------------------------
   Componentes de gráficos
   --------------------------------------------------------------------- */

// Columnas apiladas por mes (una columna por mes, un segmento por serie)
function columnasApiladas(cont, { meses, series, valor, maximo, resaltados, alClic, tip }) {
  const { svg, ancho } = lienzo(cont, 290);
  const m = { izq: 52, der: 8, arr: 12, aba: 30 };
  const ticks = marcas(Math.max(maximo, 1));
  const y = escala(0, ticks.at(-1), 290 - m.aba, m.arr);
  const paso = (ancho - m.izq - m.der) / meses.length;
  const w = Math.max(4, paso * 0.68);
  for (const t of ticks) {
    el("line", { x1: m.izq, x2: ancho - m.der, y1: y(t), y2: y(t), class: t === 0 ? "lin-base" : "lin-grilla" }, svg);
    el("text", { x: m.izq - 8, y: y(t) + 4, "text-anchor": "end", class: "eje-txt" }, svg).textContent = t === 0 ? "0" : `${fmt(t / 1e6)} M`;
  }
  meses.forEach((mes, i) => {
    const x = m.izq + i * paso + (paso - w) / 2;
    const g = el("g", { class: resaltados && !resaltados.has(mes) ? "atenuado" : null }, svg);
    let base = y(0);
    series.forEach((s, j) => {
      const v = valor(mes, s.clave);
      if (!v) return;
      const top = y(0) - (y(0) - y(v)) - (y(0) - base);
      const ultimo = j === series.length - 1 || series.slice(j + 1).every((s2) => !valor(mes, s2.clave));
      if (ultimo) barraV(g, x, top, w, base, s.color);
      else el("rect", { x, y: top, width: w, height: Math.max(0, base - top), fill: s.color }, g);
      base = top - 2; // 2px de separación entre segmentos
    });
    if (i % Math.ceil(meses.length / Math.max(4, Math.floor(ancho / 70))) === 0 || meses.length <= 12) {
      el("text", { x: x + w / 2, y: 290 - 10, "text-anchor": "middle", class: "eje-txt" }, svg).textContent = mesCorto(mes);
    }
    const hit = el("rect", { x: m.izq + i * paso, y: m.arr, width: paso, height: 290 - m.aba - m.arr, class: `hit ${alClic ? "clicable" : ""}` }, svg);
    conTip(hit, () => tip(mes));
    if (alClic) hit.addEventListener("click", () => alClic(mes));
  });
}

// Columnas agrupadas por mes
function columnasAgrupadas(cont, { meses, series, valor, resaltados, tip }) {
  const { svg, ancho } = lienzo(cont, 270);
  const m = { izq: 52, der: 8, arr: 12, aba: 30 };
  const visibles = series.filter((s) => s.visible);
  const valores = meses.flatMap((mes) => visibles.map((s) => valor(mes, s.clave) || 0));
  const ticks = marcas(Math.max(...valores, 1));
  const y = escala(0, ticks.at(-1), 270 - m.aba, m.arr);
  const paso = (ancho - m.izq - m.der) / meses.length;
  const grupo = paso * 0.74;
  const w = Math.max(2, (grupo - 2 * (visibles.length - 1)) / Math.max(1, visibles.length));
  for (const t of ticks) {
    el("line", { x1: m.izq, x2: ancho - m.der, y1: y(t), y2: y(t), class: t === 0 ? "lin-base" : "lin-grilla" }, svg);
    el("text", { x: m.izq - 8, y: y(t) + 4, "text-anchor": "end", class: "eje-txt" }, svg).textContent = t === 0 ? "0" : `${fmt(t / 1e6)} M`;
  }
  meses.forEach((mes, i) => {
    const x0 = m.izq + i * paso + (paso - grupo) / 2;
    const g = el("g", { class: resaltados && !resaltados.has(mes) ? "atenuado" : null }, svg);
    visibles.forEach((s, j) => {
      const v = valor(mes, s.clave);
      if (v) barraV(g, x0 + j * (w + 2), y(v), w, y(0), s.color);
    });
    if (i % Math.ceil(meses.length / Math.max(4, Math.floor(ancho / 70))) === 0) {
      el("text", { x: x0 + grupo / 2, y: 270 - 10, "text-anchor": "middle", class: "eje-txt" }, svg).textContent = mesCorto(mes);
    }
    const hit = el("rect", { x: m.izq + i * paso, y: m.arr, width: paso, height: 270 - m.aba - m.arr, class: "hit" }, svg);
    conTip(hit, () => tip(mes));
  });
}

// Barras horizontales con etiqueta a la izquierda y valor a la derecha
function barrasH(cont, items, { formato, alClic } = {}) {
  const fila = 34;
  const alto = items.length * fila + 6;
  const { svg, ancho } = lienzo(cont, alto);
  const izq = Math.min(190, Math.max(96, ancho * 0.32));
  const der = 96;
  const max = Math.max(...items.map((it) => it.valor || 0), 1);
  const x = escala(0, max, izq, ancho - der);
  items.forEach((it, i) => {
    const yy = i * fila + 6;
    const g = el("g", { class: it.atenuado ? "atenuado" : null }, svg);
    el("text", { x: izq - 10, y: yy + fila / 2 + 1, "text-anchor": "end", class: "eje-txt", "dominant-baseline": "middle" }, g).textContent = it.etiqueta;
    if (it.valor) barraH(g, izq, yy + 6, x(it.valor), fila - 14, it.color);
    el("text", { x: (it.valor ? x(it.valor) : izq) + 8, y: yy + fila / 2 + 1, class: "val-txt", "dominant-baseline": "middle" }, g).textContent = formato(it);
    const hit = el("rect", { x: 0, y: yy, width: ancho, height: fila, class: `hit ${alClic ? "clicable" : ""}` }, svg);
    if (it.tip) conTip(hit, it.tip);
    if (alClic) hit.addEventListener("click", () => alClic(it));
  });
  el("line", { x1: izq, x2: izq, y1: 4, y2: alto - 2, class: "lin-base" }, svg);
}

// Líneas por mes con cursor vertical y tooltip
function lineas(cont, { meses, series, alto = 240, resaltados, cero = false, franja, formatoEje, tip, ejeX = true }) {
  const { svg, ancho } = lienzo(cont, alto);
  const m = { izq: 52, der: 12, arr: 12, aba: ejeX ? 30 : 10 };
  const todos = series.flatMap((s) => s.valores.filter((v) => v != null));
  const ticks = marcas(Math.max(...todos, cero ? 0 : 1), Math.min(...todos, 0) < 0 ? Math.min(...todos) : 0);
  const y = escala(ticks[0], ticks.at(-1), alto - m.aba, m.arr);
  const paso = (ancho - m.izq - m.der) / meses.length;
  const x = (i) => m.izq + paso * i + paso / 2;
  if (franja) {
    const idx = franja.map((f) => meses.indexOf(f)).filter((i) => i >= 0);
    if (idx.length) el("rect", { x: m.izq + paso * Math.min(...idx), y: m.arr, width: paso * idx.length, height: alto - m.aba - m.arr, fill: COLOR("--franja") }, svg);
  }
  if (resaltados) {
    meses.forEach((mes, i) => {
      if (resaltados.has(mes)) el("rect", { x: m.izq + paso * i, y: m.arr, width: paso, height: alto - m.aba - m.arr, fill: COLOR("--suave") }, svg);
    });
  }
  for (const t of ticks) {
    el("line", { x1: m.izq, x2: ancho - m.der, y1: y(t), y2: y(t), class: t === ticks[0] ? "lin-base" : "lin-grilla" }, svg);
    el("text", { x: m.izq - 8, y: y(t) + 4, "text-anchor": "end", class: "eje-txt" }, svg).textContent = formatoEje(t);
  }
  if (cero && ticks[0] < 0) el("line", { x1: m.izq, x2: ancho - m.der, y1: y(0), y2: y(0), class: "lin-cero" }, svg);
  if (ejeX) {
    meses.forEach((mes, i) => {
      if (i % Math.ceil(meses.length / Math.max(4, Math.floor(ancho / 70))) === 0) {
        el("text", { x: x(i), y: alto - 10, "text-anchor": "middle", class: "eje-txt" }, svg).textContent = mesCorto(mes);
      }
    });
  }
  for (const s of series) {
    let d = "";
    s.valores.forEach((v, i) => {
      if (v == null) return;
      d += `${d && s.valores[i - 1] != null ? "L" : "M"}${x(i)},${y(v)} `;
    });
    el("path", { d, fill: "none", stroke: s.color, "stroke-width": 2, "stroke-linejoin": "round", "stroke-linecap": "round" }, svg);
    s.valores.forEach((v, i) => {
      if (v != null && resaltados && resaltados.has(meses[i]) && resaltados.size <= 12) {
        el("circle", { cx: x(i), cy: y(v), r: 4, fill: s.color, stroke: COLOR("--tarjeta"), "stroke-width": 2 }, svg);
      }
    });
  }
  const cursor = el("line", { y1: m.arr, y2: alto - m.aba, class: "cursor", visibility: "hidden" }, svg);
  const puntos = series.map((s) => el("circle", { r: 4, fill: s.color, stroke: COLOR("--tarjeta"), "stroke-width": 2, visibility: "hidden" }, svg));
  const zona = el("rect", { x: m.izq, y: m.arr, width: ancho - m.izq - m.der, height: alto - m.aba - m.arr, class: "hit" }, svg);
  zona.addEventListener("mousemove", (e) => {
    const r = svg.getBoundingClientRect();
    const px = ((e.clientX - r.left) / r.width) * ancho;
    const i = Math.max(0, Math.min(meses.length - 1, Math.floor((px - m.izq) / paso)));
    cursor.setAttribute("x1", x(i)); cursor.setAttribute("x2", x(i)); cursor.setAttribute("visibility", "visible");
    series.forEach((s, j) => {
      const v = s.valores[i];
      if (v == null) { puntos[j].setAttribute("visibility", "hidden"); return; }
      puntos[j].setAttribute("cx", x(i)); puntos[j].setAttribute("cy", y(v)); puntos[j].setAttribute("visibility", "visible");
    });
    mostrarTip(tip(meses[i], i), e);
  });
  zona.addEventListener("mouseleave", () => {
    cursor.setAttribute("visibility", "hidden");
    puntos.forEach((p) => p.setAttribute("visibility", "hidden"));
    ocultarTip();
  });
}

// Anillo con valor al centro
function anillo(cont, { porciones, centro, sub }) {
  const tam = 230;
  cont.innerHTML = "";
  const svg = el("svg", { viewBox: `0 0 ${tam} ${tam}`, width: tam, height: tam, role: "img", style: "max-width:230px;margin:0 auto" }, cont);
  const cx = tam / 2, cy = tam / 2, R = 100, r = 70;
  let ang = -Math.PI / 2;
  const sep = 0.02;
  for (const p of porciones) {
    if (!p.parte) continue;
    const a0 = ang + sep / 2, a1 = ang + p.parte * 2 * Math.PI - sep / 2;
    ang += p.parte * 2 * Math.PI;
    const grande = a1 - a0 > Math.PI ? 1 : 0;
    const pt = (rad, a) => `${cx + rad * Math.cos(a)},${cy + rad * Math.sin(a)}`;
    const d = `M${pt(R, a0)} A${R},${R} 0 ${grande} 1 ${pt(R, a1)} L${pt(r, a1)} A${r},${r} 0 ${grande} 0 ${pt(r, a0)} Z`;
    const seg = el("path", { d, fill: p.color }, svg);
    conTip(seg, p.tip);
  }
  el("text", { x: cx, y: cy + 4, "text-anchor": "middle", style: `font-size:34px;font-weight:700;fill:${COLOR("--tinta")}` }, svg).textContent = centro;
  el("text", { x: cx, y: cy + 26, "text-anchor": "middle", class: "eje-txt" }, svg).textContent = sub;
}

// Minigráfico de fondo de las tarjetas KPI
function minigrafico(valores, meses, resaltados, color) {
  const W = 220, H = 44;
  const svg = el("svg", { viewBox: `0 0 ${W} ${H}`, preserveAspectRatio: "none", "aria-hidden": "true" });
  const vals = valores.filter((v) => v != null);
  if (!vals.length) return svg;
  const y = escala(Math.min(...vals, 0), Math.max(...vals), H - 3, 3);
  const x = (i) => (i / Math.max(1, meses.length - 1)) * W;
  let d = "";
  valores.forEach((v, i) => { if (v != null) d += `${d ? "L" : "M"}${x(i)},${y(v)} `; });
  el("path", { d: `${d} L${W},${H} L0,${H} Z`, fill: color, opacity: 0.08 }, svg);
  el("path", { d, fill: "none", stroke: color, "stroke-width": 1.5, opacity: resaltados ? 0.35 : 0.9, "vector-effect": "non-scaling-stroke" }, svg);
  if (resaltados) {
    let dr = "";
    valores.forEach((v, i) => {
      if (v == null || !resaltados.has(meses[i])) return;
      dr += `${dr && resaltados.has(meses[i - 1]) ? "L" : "M"}${x(i)},${y(v)} `;
    });
    el("path", { d: dr, fill: "none", stroke: color, "stroke-width": 2.5, "stroke-linecap": "round", "vector-effect": "non-scaling-stroke" }, svg);
  }
  return svg;
}

/* ---------------------------------------------------------------------
   Secciones
   --------------------------------------------------------------------- */
const listaMeses = () => D.meses.map((m) => m.period);

function chips(aplica) {
  const nombres = { per: "Período", can: "Canal", prov: "Provincia" };
  return `<div class="chips">${Object.entries(nombres).map(([c, n]) =>
    `<span class="chip ${aplica.includes(c) ? "" : "off"}" title="${aplica.includes(c) ? "Este filtro aplica" : "Este filtro no aplica"}">${n}</span>`).join("")}</div>`;
}

function renderResumen() {
  const per = periodo();
  const meses = listaMeses();
  const res = mesesDelPeriodo();
  const v = filaVentas(per);
  const cli = D.clientes.get(per);
  const n = D.nps.get(k(per, F.canal));
  const conIva = F.iva === "con";
  const tarjetas = [
    {
      nombre: `Ventas ${conIva ? "con" : "sin"} IVA`,
      valor: pesosM(ventasDe(v)),
      det: v ? `${conIva ? "Sin" : "Con"} IVA: ${pesosM(num(conIva ? v.sales_net_amount : v.sales_amount))}` : "Sin datos",
      serie: meses.map((m) => ventasDe(filaVentas(m))), color: "--serie", aplica: ["per", "can", "prov"],
    },
    {
      nombre: "Pedidos que cuentan como venta",
      valor: entero(v && num(v.sale_orders)),
      det: v ? `de ${entero(num(v.orders_total))} pedidos (${pct(num(v.sale_order_share))})` : "Sin datos",
      serie: meses.map((m) => { const f = filaVentas(m); return f ? num(f.sale_orders) : null; }), color: "--serie", aplica: ["per", "can", "prov"],
    },
    {
      nombre: `Ticket promedio ${conIva ? "con" : "sin"} IVA`,
      valor: pesos(ticketDe(v)),
      det: v ? `Sin envío (con IVA): ${pesos(num(v.ticket_no_shipping))}` : "Sin datos",
      serie: meses.map((m) => ticketDe(filaVentas(m))), color: "--serie", aplica: ["per", "can", "prov"],
    },
    {
      nombre: "Usuarios activos",
      valor: entero(cli && num(cli.active_users)),
      det: cli ? `${entero(num(cli.sessions))} sesiones · ${pct(num(cli.logged_share))} logueadas` : "Sin datos",
      serie: meses.map((m) => { const f = D.clientes.get(m); return f ? num(f.active_users) : null; }), color: "--serie", aplica: ["per"],
    },
    {
      nombre: "NPS",
      valor: dec1(n && num(n.nps)),
      det: n ? `${entero(num(n.responses))} respuestas · ${pct(num(n.promoter_share), 0)} promotores` : "Sin datos",
      serie: meses.map((m) => { const f = D.nps.get(k(m, F.canal)); return f ? num(f.nps) : null; }), color: "--serie", aplica: ["per", "can"],
    },
  ];
  const cont = document.getElementById("kpis");
  cont.innerHTML = "";
  for (const t of tarjetas) {
    const art = document.createElement("article");
    art.className = "kpi";
    art.innerHTML = `<p class="kpi-nom">${t.nombre}</p><p class="kpi-val">${t.valor}</p><p class="kpi-det">${t.det}</p>${chips(t.aplica)}<div class="kpi-spark"></div>`;
    art.querySelector(".kpi-spark").appendChild(minigrafico(t.serie, meses, res, COLOR(t.color)));
    cont.appendChild(art);
  }
  document.getElementById("sub-resumen").innerHTML =
    `Período: <strong>${esc(etiquetaPeriodo())}</strong> · Canal: <strong>${esc(CANAL_NOMBRE[F.canal])}</strong> · Provincia: <strong>${esc(F.prov)}</strong>. ` +
    "La línea de fondo es la evolución mensual; en trazo fuerte, los meses del período elegido.";
}

function canalesVisibles() {
  return (F.canal === "Todos" ? ["ONLINE", "OFFLINE"] : [F.canal]).map((c) => ({ clave: c, nombre: CANAL_NOMBRE[c], color: COLOR(CANAL_COLOR[c]) }));
}
function leyenda(id, items) {
  document.getElementById(id).innerHTML = items.map((it) => `<li><i class="clave ${it.linea ? "linea" : ""}" style="background:${it.color}"></i>${esc(it.nombre)}</li>`).join("");
}

function renderVentas() {
  const per = periodo();
  const meses = listaMeses();
  const res = mesesDelPeriodo();
  const series = canalesVisibles();
  leyenda("ley-meses", series);
  const iva = F.iva === "con" ? "con IVA" : "sin IVA";

  columnasApiladas(document.getElementById("g-meses"), {
    meses, series, resaltados: res,
    valor: (mes, canal) => ventasDe(filaVentas(mes, canal)),
    maximo: Math.max(...meses.map((mes) => ventasDe(filaVentas(mes)) || 0)),
    alClic: (mes) => { if (F.mes === mes) F.mes = ""; else { F.mes = mes; F.anio = mes.slice(0, 4); } render(); },
    tip: (mes) => {
      const total = filaVentas(mes);
      return `<b>${esc(D.etiqueta.get(mes))}</b><br>` + series.map((s) => filaTip(s.color, `${s.nombre}: ${pesosM(ventasDe(filaVentas(mes, s.clave)))}`)).join("") +
        (F.canal === "Todos" ? `Total ${iva}: <b>${pesosM(ventasDe(total))}</b>` : "");
    },
  });

  // Tabla de datos (accesible): cada celda es una fila del mart
  const tabla = document.getElementById("t-meses");
  tabla.innerHTML = `<thead><tr><th>Mes</th>${series.map((s) => `<th>${s.nombre}</th>`).join("")}${F.canal === "Todos" ? "<th>Total</th>" : ""}</tr></thead><tbody>` +
    meses.map((mes) => `<tr><td>${esc(D.etiqueta.get(mes))}</td>${series.map((s) => `<td>${pesos(ventasDe(filaVentas(mes, s.clave)))}</td>`).join("")}${F.canal === "Todos" ? `<td>${pesos(ventasDe(filaVentas(mes)))}</td>` : ""}</tr>`).join("") + "</tbody>";

  // Provincias
  const provs = D.provincias.filter((p) => p.province !== "Todas").map((p) => {
    const f = filaVentas(per, F.canal, p.province);
    return {
      etiqueta: p.province, valor: ventasDe(f), color: COLOR("--serie"), atenuado: F.prov !== "Todas" && F.prov !== p.province, prov: p.province,
      tip: () => f ? `<b>${esc(p.province)}</b><br>Ventas ${iva}: ${pesosM(ventasDe(f))}<br>Pedidos válidos: ${entero(num(f.sale_orders))}<br>Ticket: ${pesos(ticketDe(f))}` : `<b>${esc(p.province)}</b><br>Sin ventas`,
    };
  }).sort((a, b) => (b.valor || 0) - (a.valor || 0));
  barrasH(document.getElementById("g-prov"), provs, {
    formato: (it) => pesosM(it.valor),
    alClic: (it) => { F.prov = F.prov === it.prov ? "Todas" : it.prov; render(); },
  });

  // Ticket por canal
  const filas = ["ONLINE", "OFFLINE", "Todos"].map((c) => ({ c, f: filaVentas(per, c) }));
  document.getElementById("g-ticket").innerHTML = `<table class="tabla"><thead><tr><th>Canal</th><th>Con IVA</th><th>Sin IVA</th><th>Sin envío</th></tr></thead><tbody>` +
    filas.map(({ c, f }) => `<tr class="${F.canal === c ? "sel" : ""}"><td>${c === "Todos" ? "Total" : `<i class="clave ${c.toLowerCase()}"></i> ${CANAL_NOMBRE[c]}`}</td>` +
      `<td>${pesos(f && num(f.ticket_amount))}</td><td>${pesos(f && num(f.ticket_net_amount))}</td><td>${pesos(f && num(f.ticket_no_shipping))}</td></tr>`).join("") +
    `</tbody></table><p class="ayuda" style="margin-top:10px">Pedidos válidos: ${filas.map(({ c, f }) => `${c === "Todos" ? "total" : CANAL_NOMBRE[c].toLowerCase()} ${entero(f && num(f.sale_orders))}`).join(" · ")}.</p>`;

  // Productos
  const prods = D.productosNombres.map((p, i) => ({ clave: p, nombre: p, color: COLOR(PROD_COLOR[i % 2]), visible: !prodOcultos.has(p) }));
  const ley = document.getElementById("ley-prod");
  ley.innerHTML = prods.map((p) => `<li><button type="button" data-prod="${esc(p.clave)}" aria-pressed="${p.visible}"><i class="clave" style="background:${p.color}"></i>${esc(p.nombre)}</button></li>`).join("");
  ley.querySelectorAll("button").forEach((b) => b.addEventListener("click", () => {
    const p = b.dataset.prod;
    if (prodOcultos.has(p)) prodOcultos.delete(p); else if (prodOcultos.size < prods.length - 1) prodOcultos.add(p);
    renderVentas();
  }));
  const filaProd = (per2, prod) => (D.productos.get(k(per2, F.canal, F.prov)) || []).find((f) => f.product === prod);
  columnasAgrupadas(document.getElementById("g-prod"), {
    meses, series: prods, resaltados: res,
    valor: (mes, prod) => { const f = filaProd(mes, prod); return f ? num(f.sales_line_amount) : null; },
    tip: (mes) => `<b>${esc(D.etiqueta.get(mes))}</b><br>` + prods.filter((p) => p.visible).map((p) => {
      const f = filaProd(mes, p.clave);
      return filaTip(p.color, `${p.nombre}: ${f ? `${pesosM(num(f.sales_line_amount))} · ${entero(num(f.units))} u. · puesto ${f.rank_in_period}` : nada}`);
    }).join(""),
  });
  const rep = D.productos.get(k(per, F.canal, F.prov)) || [];
  document.getElementById("g-prod-rep").innerHTML = `<div class="reparto"><p class="rep-pie">Reparto en ${esc(etiquetaPeriodo())}</p>` +
    prods.map((p) => {
      const f = rep.find((r) => r.product === p.clave);
      return `<div class="rep-fila"><p><span>${esc(p.nombre)}</span><strong>${pct(f && num(f.share_of_period))}</strong></p>` +
        `<div class="rep-barra"><i style="width:${f ? num(f.share_of_period) * 100 : 0}%;background:${p.color}"></i></div>` +
        `<p class="rep-pie">${f ? `${pesosM(num(f.sales_line_amount))} · ${entero(num(f.units))} unidades · puesto ${f.rank_in_period}` : "Sin ventas"}</p></div>`;
    }).join("") + "</div>";

  // Estados
  const est = (D.estados.get(k(per, F.canal, F.prov)) || []).slice().sort((a, b) => num(b.orders) - num(a.orders));
  barrasH(document.getElementById("g-estados"), est.map((f) => ({
    etiqueta: f.status_description, valor: num(f.orders), color: COLOR(f.is_sale === "true" ? "--si" : "--no"),
    tip: () => `<b>${esc(f.status_code)}</b> · ${esc(f.status_description)}<br>${entero(num(f.orders))} pedidos · ${pesosM(num(f.total_amount))}<br>${f.is_sale === "true" ? "Cuenta como venta" : "No cuenta como venta"}`,
  })), { formato: (it) => entero(it.valor) });

  // Pagos
  const pagos = (D.pagos.get(k(per, F.canal)) || []).slice().sort((a, b) => num(b.failed_share) - num(a.failed_share));
  barrasH(document.getElementById("g-pagos"), pagos.map((f) => ({
    etiqueta: f.payment_method.replace(" (Mercado Pago)", ""), valor: num(f.failed_share), color: COLOR("--serie"),
    tip: () => `<b>${esc(f.payment_method)}</b><br>${entero(num(f.payments))} pagos · ${entero(num(f.failed))} rechazados<br>Rechazo: ${pct(num(f.failed_share))}`,
  })), { formato: (it) => pct(it.valor) });
}

function renderClientes() {
  const per = periodo();
  const meses = listaMeses();
  const res = mesesDelPeriodo();
  const c = D.clientes.get(per);
  document.getElementById("k-clientes").innerHTML = [
    ["Usuarios activos", entero(c && num(c.active_users)), esc(etiquetaPeriodo())],
    ["Sesiones", entero(c && num(c.sessions)), "visitas a la web"],
    ["Sesiones logueadas", pct(c && num(c.logged_share)), `${entero(c && num(c.logged_sessions))} sesiones`],
  ].map(([t, v, s]) => `<div class="mini"><p>${t}</p><strong>${v}</strong><span>${s}</span></div>`).join("");

  lineas(document.getElementById("g-usuarios"), {
    meses, resaltados: res, alto: 220,
    series: [{ color: COLOR("--serie"), valores: meses.map((m) => { const f = D.clientes.get(m); return f ? num(f.active_users) : null; }) }],
    formatoEje: (t) => entero(t),
    tip: (mes) => { const f = D.clientes.get(mes); return `<b>${esc(D.etiqueta.get(mes))}</b><br>Usuarios activos: <b>${entero(f && num(f.active_users))}</b><br>Sesiones: ${entero(f && num(f.sessions))}<br>Logueadas: ${pct(f && num(f.logged_share))}`; },
  });

  for (const [id, apertura] of [["g-origen", "Origen"], ["g-disp", "Dispositivo"]]) {
    const filas = (D.sesiones.get(k(per, apertura)) || []).slice().sort((a, b) => num(b.sessions) - num(a.sessions));
    barrasH(document.getElementById(id), filas.map((f) => ({
      etiqueta: f.label, valor: num(f.sessions), color: COLOR("--serie"), share: num(f.share),
      tip: () => `<b>${esc(f.label)}</b><br>${entero(num(f.sessions))} sesiones · ${pct(num(f.share))}`,
    })), { formato: (it) => `${entero(it.valor)} · ${pct(it.share, 0)}` });
  }
}

function renderExperiencia() {
  const per = periodo();
  const meses = listaMeses();
  const res = mesesDelPeriodo();
  const n = D.nps.get(k(per, F.canal));
  const grupos = (D.npsGrupos.get(k(per, F.canal)) || []).slice().sort((a, b) => num(a.sort_order) - num(b.sort_order));
  anillo(document.getElementById("g-dona"), {
    porciones: grupos.map((g) => ({
      parte: num(g.share), color: COLOR(NPS_COLOR[g.nps_group]),
      tip: `<b>${esc(g.nps_group)}</b><br>${entero(num(g.responses))} respuestas · ${pct(num(g.share))}`,
    })),
    centro: dec1(n && num(n.nps)), sub: `NPS · ${CANAL_NOMBRE[F.canal]}`,
  });
  document.getElementById("ley-nps").innerHTML = grupos.map((g) =>
    `<li><i class="clave" style="background:${COLOR(NPS_COLOR[g.nps_group])}"></i>${esc(g.nps_group)}: ${pct(num(g.share))} (${entero(num(g.responses))})</li>`).join("");

  const e = D.entregas.get(k(per, F.canal, F.prov));
  document.getElementById("k-entregas").innerHTML = [
    ["Del pedido a la puerta", e ? `${dec1(num(e.avg_days_order_to_door))} días` : nada, e ? `promedio · 9 de cada 10 en ${dec1(num(e.p90_days_order_to_door))} días o menos` : ""],
    ["En el correo", e ? `${dec1(num(e.avg_days_to_deliver))} días` : nada, "del despacho a la entrega"],
    ["Tardaron más de 7 días", pct(e && num(e.late_share)), "de los envíos entregados"],
    ["Envíos entregados", entero(e && num(e.delivered_shipments)), `${esc(etiquetaPeriodo())} · ${esc(F.prov)}`],
  ].map(([t, v, s]) => `<div class="mini"><p>${t}</p><strong>${v}</strong><span>${s}</span></div>`).join("");

  const series = canalesVisibles();
  leyenda("ley-nps-mes", series.map((s) => ({ ...s, linea: true })));
  lineas(document.getElementById("g-nps-mes"), {
    meses, resaltados: res, cero: true, franja: FRANJA, alto: 220, ejeX: false,
    series: series.map((s) => ({ color: s.color, valores: meses.map((m) => { const f = D.nps.get(k(m, s.clave)); return f ? num(f.nps) : null; }) })),
    formatoEje: (t) => fmt(t),
    tip: (mes) => `<b>${esc(D.etiqueta.get(mes))}</b><br>` + series.map((s) => { const f = D.nps.get(k(mes, s.clave)); return filaTip(s.color, `NPS ${s.nombre}: <b>${dec1(f && num(f.nps))}</b>`); }).join(""),
  });
  lineas(document.getElementById("g-dias"), {
    meses, resaltados: res, franja: FRANJA, alto: 170,
    series: [{ color: COLOR("--serie"), valores: meses.map((m) => { const f = D.entregas.get(k(m, F.canal, F.prov)); return f ? num(f.avg_days_to_deliver) : null; }) }],
    formatoEje: (t) => `${fmt(t)} d`,
    tip: (mes) => { const f = D.entregas.get(k(mes, F.canal, F.prov)); return `<b>${esc(D.etiqueta.get(mes))}</b><br>Días en el correo: <b>${dec1(f && num(f.avg_days_to_deliver))}</b><br>Del pedido a la puerta: ${dec1(f && num(f.avg_days_order_to_door))}<br>Más de 7 días: ${pct(f && num(f.late_share))}`; },
  });
}

function renderCrecimiento() {
  const formato = (u, v) => (u === "money" ? (v >= 1e6 ? pesosM(v) : pesos(v)) : u === "score" ? dec1(v) : entero(v));
  document.getElementById("g-crec").innerHTML = D.crecimiento.map((f) => {
    const cambio = num(f.change);
    const clase = Math.abs(cambio) <= 1 ? "igual" : cambio > 0 ? "sube" : "baja";
    const flecha = clase === "igual" ? "●" : cambio > 0 ? "▲" : "▼";
    const unidad = f.change_unit === "puntos" ? " pts" : " %";
    const v24 = num(f.value_2024), v25 = num(f.value_2025);
    const max = Math.max(v24, v25);
    return `<article class="crec-item"><h3>${esc(f.kpi)}</h3>` +
      `<div class="crec-vals"><span class="ant">${formato(f.unit, v24)}</span><span class="flecha">→</span><span class="act">${formato(f.unit, v25)}</span></div>` +
      `<span class="pildora ${clase}">${flecha} ${cambio > 0 ? "+" : ""}${fmt(cambio, 1)}${unidad}${clase === "igual" ? " · estable" : ""}</span>` +
      (f.unit === "score" ? "" : `<div class="crec-barras" aria-hidden="true"><div>2024<i style="width:${(v24 / max) * 100}%;background:var(--no)"></i></div><div>2025<i style="width:${(v25 / max) * 100}%;background:var(--acento)"></i></div></div>`) +
      "</article>";
  }).join("");
}

/* ---------------------------------------------------------------------
   Hallazgos: cada uno lleva al gráfico que lo respalda
   --------------------------------------------------------------------- */
// Los números de cada hallazgo se buscan en los marts (no se calculan acá);
// la interpretación es texto de análisis.
const busca = {
  dias: (mes) => num(D.entregas.get(k(mes, "Todos", "Todas"))?.avg_days_to_deliver),
  nps: (per, canal) => num(D.nps.get(k(per, canal))?.nps),
  crec: (kpi) => D.crecimiento.find((f) => f.kpi === kpi),
  rechazo: (medio) => num((D.pagos.get(k("Todo", "Todos")) || []).find((f) => f.payment_method.startsWith(medio))?.failed_share),
  estado: (codigo) => (D.estados.get(k("Todo", "Todos", "Todas")) || []).find((f) => f.status_code === codigo),
  cliente: (mes) => D.clientes.get(mes),
  sesiones: (apertura, valor) => num((D.sesiones.get(k("Todo", apertura)) || []).find((f) => f.label === valor)?.share),
  lider: (producto) => D.lideres.find((f) => f.product === producto),
};
const variacion = (kpi) => {
  const f = busca.crec(kpi);
  if (!f) return nada;
  const c = num(f.change);
  return `${c > 0 ? "+" : ""}${fmt(c, 1)}${f.change_unit === "puntos" ? " pts" : " %"}`;
};

const HALLAZGOS = [
  {
    titulo: "En julio y agosto de 2024 el NPS online se desplomó por la demora del correo",
    hecho: () => `Los días del despacho a la entrega pasaron de ${dec1(busca.dias("2024-06"))} en junio a ${dec1(busca.dias("2024-07"))} en julio y ${dec1(busca.dias("2024-08"))} en agosto, y volvieron a ${dec1(busca.dias("2024-10"))} en octubre. ` +
      `En esos meses el NPS online cayó de ${dec1(busca.nps("2024-06", "ONLINE"))} a ${dec1(busca.nps("2024-07", "ONLINE"))} y ${dec1(busca.nps("2024-08", "ONLINE"))}; ` +
      `el de las tiendas, que no usan envío, no cayó (${dec1(busca.nps("2024-08", "OFFLINE"))} en agosto).`,
    interp: "La caída se explica por la demora y no por el producto: coinciden las fechas y el canal sin envío funciona como grupo de control. Conviene tener un segundo correo y avisar al cliente cuando el envío se demora.",
    boton: "Ver NPS y entregas", filtros: { anio: "2024", mes: "", canal: "Todos", prov: "Todas" }, destino: "g-nps-mes",
  },
  {
    titulo: "La venta crece por más clientes, no por compras más caras, y todo el crecimiento es online",
    hecho: () => `Enero a septiembre, 2025 contra 2024: ventas ${variacion("Ventas con IVA")}, pedidos válidos ${variacion("Pedidos válidos")}, ` +
      `clientes que compraron ${variacion("Clientes que compraron")}, ticket ${variacion("Ticket promedio (con IVA)")}. ` +
      `Tienda online ${variacion("Ventas tienda online")}; tiendas físicas ${variacion("Ventas tiendas físicas")}.`,
    interp: "El negocio crece captando clientes por el canal online, no subiendo precios ni el gasto por compra.",
    boton: "Ver crecimiento", filtros: null, destino: "crecimiento",
  },
  {
    titulo: "El NPS online es más bajo que el de las tiendas físicas",
    hecho: () => `NPS de todo el período: tiendas físicas ${dec1(busca.nps("Todo", "OFFLINE"))}, tienda online ${dec1(busca.nps("Todo", "ONLINE"))}.`,
    interp: "Es consistente con el hallazgo de la demora: el canal online depende del correo y el de tienda no.",
    boton: "Ver NPS online", filtros: { anio: "Todo", mes: "", canal: "ONLINE", prov: "Todas" }, destino: "g-dona",
  },
  {
    titulo: "Mercado Pago rechaza más del doble que la tarjeta",
    hecho: () => {
      const c = busca.estado("CANCELLED");
      return `Se rechaza el ${pct(busca.rechazo("Pasarela"))} de los pagos por pasarela contra el ${pct(busca.rechazo("Tarjeta"))} con tarjeta. ` +
        `Las cancelaciones suman ${entero(c && num(c.orders))} pedidos y ${pesosM(c && num(c.total_amount))} que no se concretaron.`;
    },
    interp: "Es un punto concreto para recuperar ventas: reintentos o un medio alternativo en el momento del rechazo.",
    boton: "Ver rechazos de pago", filtros: { anio: "Todo", mes: "", canal: "Todos", prov: "Todas" }, destino: "g-pagos",
  },
  {
    titulo: "Los usuarios activos se duplicaron y la mayoría de las visitas llega desde el celular",
    hecho: () => {
      const a = busca.cliente(D.meses[0].period), b = busca.cliente(D.meses.at(-1).period);
      return `Los usuarios activos por mes pasaron de ${entero(a && num(a.active_users))} (${D.meses[0].period_label.toLowerCase()}) a ${entero(b && num(b.active_users))} (${D.meses.at(-1).period_label.toLowerCase()}), ` +
        `y las sesiones logueadas, del ${pct(a && num(a.logged_share), 0)} al ${pct(b && num(b.logged_share), 0)}. ` +
        `El ${pct(busca.sesiones("Dispositivo", "Celular"))} de las visitas es desde el celular.`;
    },
    interp: "Parte del crecimiento puede deberse a que más gente inicia sesión, no a que haya más audiencia. La experiencia móvil es prioritaria.",
    boton: "Ver clientes", filtros: { anio: "Todo", mes: "", canal: "Todos", prov: "Todas" }, destino: "g-usuarios",
  },
  {
    titulo: "Los dos productos se reparten la venta casi parejo",
    hecho: () => {
      const s = busca.lider("Sport B Bottle"), c = busca.lider("Classic A Bottle");
      return `Sport B es el primero en pesos en ${s ? s.months_top_sales : nada} de los ${s ? s.months : nada} meses, por su precio más alto; ` +
        `Classic A vende más unidades en ${c ? c.months_top_units : nada} de los ${c ? c.months : nada}.`;
    },
    interp: "Con dos productos, un ranking dice poco: por eso el tablero muestra los dos lado a lado cada mes.",
    boton: "Ver productos", filtros: { anio: "Todo", mes: "", canal: "Todos", prov: "Todas" }, destino: "g-prod",
  },
];

function renderHallazgos() {
  const cont = document.getElementById("hallazgos-lista");
  cont.innerHTML = HALLAZGOS.map((h, i) => `<article class="hall"><h3>${i + 1}. ${esc(h.titulo)}</h3>` +
    `<p><span class="tipo">Hecho</span>${esc(h.hecho())}</p><p><span class="tipo interp">Interpretación</span>${esc(h.interp)}</p>` +
    `<button type="button" data-i="${i}">${esc(h.boton)} →</button></article>`).join("");
  cont.querySelectorAll("button").forEach((b) => b.addEventListener("click", () => {
    const h = HALLAZGOS[Number(b.dataset.i)];
    if (h.filtros) { F = { ...F, ...h.filtros }; render(); }
    const destino = document.getElementById(h.destino);
    const tarjeta = destino.closest(".tarjeta") || destino;
    tarjeta.scrollIntoView({ behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth", block: "center" });
    tarjeta.classList.remove("destacar");
    void tarjeta.offsetWidth;
    tarjeta.classList.add("destacar");
  }));
}

/* ---------------------------------------------------------------------
   Controles
   --------------------------------------------------------------------- */
function pintarControles() {
  const marcar = (id, valor) => document.querySelectorAll(`#${id} button`).forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.v === valor)));
  marcar("f-anio", F.anio);
  marcar("f-canal", F.canal);
  marcar("f-iva", F.iva);
  const selMes = document.getElementById("f-mes");
  const meses = D.meses.filter((m) => F.anio === "Todo" || m.period.startsWith(F.anio));
  selMes.innerHTML = `<option value="">Todos los meses</option>` + meses.map((m) => `<option value="${m.period}">${esc(m.period_label)}</option>`).join("");
  selMes.value = F.mes;
  document.getElementById("f-prov").value = F.prov;
}

function iniciarControles() {
  document.getElementById("f-canal").innerHTML = D.canales.map((c) => `<button type="button" data-v="${esc(c.channel)}" aria-pressed="false">${esc(c.channel === "Todos" ? "Todos" : c.channel === "ONLINE" ? "Online" : "Tiendas")}</button>`).join("");
  document.getElementById("f-prov").innerHTML = D.provincias.map((p) => `<option value="${esc(p.province)}">${esc(p.province)}</option>`).join("");
  const enSeg = (id, fn) => document.getElementById(id).addEventListener("click", (e) => {
    const b = e.target.closest("button");
    if (b) { fn(b.dataset.v); render(); }
  });
  enSeg("f-anio", (v) => { F.anio = v; F.mes = ""; });
  enSeg("f-canal", (v) => { F.canal = v; });
  enSeg("f-iva", (v) => { F.iva = v; });
  document.getElementById("f-mes").addEventListener("change", (e) => {
    F.mes = e.target.value;
    if (F.mes) F.anio = F.mes.slice(0, 4);
    render();
  });
  document.getElementById("f-prov").addEventListener("change", (e) => { F.prov = e.target.value; render(); });
  document.getElementById("f-reset").addEventListener("click", () => { F = inicial(); prodOcultos.clear(); render(); });

  // Sección activa en la barra
  const enlaces = [...document.querySelectorAll(".secciones a")];
  const obs = new IntersectionObserver((entradas) => {
    for (const en of entradas) {
      if (en.isIntersecting) enlaces.forEach((a) => a.classList.toggle("activo", a.getAttribute("href") === `#${en.target.id}`));
    }
  }, { rootMargin: "-45% 0px -50% 0px" });
  document.querySelectorAll(".sector").forEach((s) => obs.observe(s));

  let pendiente;
  window.addEventListener("resize", () => { clearTimeout(pendiente); pendiente = setTimeout(render, 150); });
  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", render);
}

function render() {
  pintarControles();
  renderResumen();
  renderVentas();
  renderClientes();
  renderExperiencia();
  renderCrecimiento();
}

/* ---------------------------------------------------------------------
   Arranque
   --------------------------------------------------------------------- */
(async function iniciar() {
  const estado = document.getElementById("estado");
  try {
    indexar(await cargar());
    iniciarControles();
    renderHallazgos();
    render();
    estado.textContent = `Datos cargados desde ${Object.keys(ARCHIVOS).length} tablas mart · ${D.etiqueta.get(D.meses[0].period)} a ${D.etiqueta.get(D.meses.at(-1).period)}.`;
    estado.classList.add("ok");
  } catch (err) {
    estado.textContent = `No se pudieron cargar los datos: ${err.message}. Si abriste el archivo con doble clic, usá un servidor local (ver README).`;
    estado.classList.add("error");
    console.error(err);
  }
})();
