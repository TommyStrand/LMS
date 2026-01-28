const courses = [
  {
    id: "course-1",
    title: "Trygg hjemmebefaring",
    summary: "Sjekklister for sikkerhet, kundedialog og kvalitetssikring.",
    modules: [
      { name: "Forberedelse og utstyr", duration: "15 min", completed: true },
      { name: "Risikovurdering på stedet", duration: "20 min", completed: true },
      { name: "Oppsummering med kunden", duration: "10 min", completed: false },
    ],
  },
  {
    id: "course-2",
    title: "Digital ordrehåndtering",
    summary: "Rutiner for opprettelse, oppfølging og avslutning av oppdrag.",
    modules: [
      { name: "Ordre i appen", duration: "12 min", completed: false },
      { name: "Dokumentasjon og bilder", duration: "18 min", completed: false },
      { name: "Faktura og signatur", duration: "8 min", completed: false },
    ],
  },
  {
    id: "course-3",
    title: "HMS og sikkerhet",
    summary: "Enkle rutiner som hindrer ulykker og gir tryggere oppdrag.",
    modules: [
      { name: "Personlig verneutstyr", duration: "14 min", completed: true },
      { name: "Arbeid i høyden", duration: "16 min", completed: true },
      { name: "Sikker avslutning", duration: "10 min", completed: true },
    ],
  },
];

const customers = [
  {
    name: "ByggPartner AS",
    course: "Trygg hjemmebefaring",
    status: "warning",
    contact: "maria@byggpartner.no",
  },
  {
    name: "Nordic Fix",
    course: "Digital ordrehåndtering",
    status: "success",
    contact: "kundeservice@nordicfix.no",
  },
  {
    name: "FixIt Pro",
    course: "HMS og sikkerhet",
    status: "info",
    contact: "post@fixitpro.no",
  },
  {
    name: "HandyHome",
    course: "Trygg hjemmebefaring",
    status: "warning",
    contact: "kontakt@handyhome.no",
  },
];

const courseList = document.getElementById("courseList");
const moduleDetail = document.getElementById("moduleDetail");
const searchInput = document.getElementById("searchInput");
const resetSearch = document.getElementById("resetSearch");
const customerRows = document.getElementById("customerRows");
const statusFilters = document.getElementById("statusFilters");
const selectedCourseLabel = document.getElementById("selectedCourseLabel");

const activeCustomers = document.getElementById("activeCustomers");
const completedCourses = document.getElementById("completedCourses");
const openTasks = document.getElementById("openTasks");
const activeCustomersDelta = document.getElementById("activeCustomersDelta");
const completedCoursesDelta = document.getElementById("completedCoursesDelta");
const openTasksDelta = document.getElementById("openTasksDelta");

let selectedCourseId = courses[0]?.id;
let activeCustomerFilter = "all";

const getProgress = (course) => {
  const completedModules = course.modules.filter((module) => module.completed).length;
  return Math.round((completedModules / course.modules.length) * 100);
};

const updateStats = () => {
  const completedCount = courses.filter((course) => getProgress(course) === 100).length;
  const followUpCount = customers.filter((customer) => customer.status === "warning").length;

  activeCustomers.textContent = customers.length;
  completedCourses.textContent = completedCount;
  openTasks.textContent = followUpCount;

  activeCustomersDelta.textContent = "+3 siste uke";
  completedCoursesDelta.textContent = `${Math.round((completedCount / courses.length) * 100)}% fullføringsgrad`;
  openTasksDelta.textContent = `${followUpCount} krever oppfølging`;
};

const renderModules = (course) => {
  moduleDetail.innerHTML = "";
  selectedCourseLabel.textContent = course.title;

  const heading = document.createElement("div");
  heading.className = "module-item summary";
  heading.innerHTML = `
    <div>
      <strong>${course.title}</strong>
      <small>${course.modules.length} moduler · ${getProgress(course)}% fullført</small>
    </div>
    <span>${getProgress(course)}%</span>
  `;

  moduleDetail.appendChild(heading);

  course.modules.forEach((module, index) => {
    const item = document.createElement("div");
    item.className = `module-item ${module.completed ? "done" : ""}`;
    item.innerHTML = `
      <div>
        <strong>${module.name}</strong>
        <small>Estimert tid: ${module.duration}</small>
      </div>
      <button class="ghost" type="button" data-module="${index}">
        ${module.completed ? "Angre" : "Marker som fullført"}
      </button>
    `;
    moduleDetail.appendChild(item);
  });
};

const renderCourses = (filter = "") => {
  courseList.innerHTML = "";
  const lowerFilter = filter.toLowerCase();

  const filteredCourses = courses.filter(
    (course) =>
      course.title.toLowerCase().includes(lowerFilter) ||
      course.summary.toLowerCase().includes(lowerFilter) ||
      course.modules.some((module) => module.name.toLowerCase().includes(lowerFilter))
  );

  filteredCourses.forEach((course) => {
    const progress = getProgress(course);
    const card = document.createElement("article");
    card.className = "course-card";
    card.innerHTML = `
      <div class="course-head">
        <h3>${course.title}</h3>
        <span class="pill">${progress}%</span>
      </div>
      <p>${course.summary}</p>
      <div class="progress" aria-label="Progress">
        <span style="width: ${progress}%"></span>
      </div>
      <small>${progress}% fullført · ${course.modules.length} moduler</small>
      <button class="primary" type="button" data-course="${course.id}">Åpne kurs</button>
    `;
    courseList.appendChild(card);
  });

  if (filteredCourses.length === 0) {
    const empty = document.createElement("p");
    empty.textContent = "Ingen kurs matcher søket. Prøv et annet ord.";
    empty.className = "muted";
    courseList.appendChild(empty);
  }

  const selectedCourse =
    filteredCourses.find((course) => course.id === selectedCourseId) ||
    filteredCourses[0] ||
    courses[0];

  if (selectedCourse) {
    selectedCourseId = selectedCourse.id;
    renderModules(selectedCourse);
  }
};

const renderCustomers = () => {
  customerRows.innerHTML = "";

  const filteredCustomers = customers.filter((customer) => {
    if (activeCustomerFilter === "all") return true;
    return customer.status === activeCustomerFilter;
  });

  filteredCustomers.forEach((customer) => {
    const row = document.createElement("div");
    row.className = "row";
    row.innerHTML = `
      <span>${customer.name}</span>
      <span>${customer.course}</span>
      <span class="status ${customer.status}">
        ${
          customer.status === "warning"
            ? "Trenger oppfølging"
            : customer.status === "info"
              ? "Pågår"
              : "Fullført"
        }
      </span>
      <span>${customer.contact}</span>
    `;
    customerRows.appendChild(row);
  });

  if (filteredCustomers.length === 0) {
    const row = document.createElement("div");
    row.className = "row";
    row.innerHTML = `
      <span>Ingen kunder i denne kategorien akkurat nå.</span>
      <span>-</span>
      <span>-</span>
      <span>-</span>
    `;
    customerRows.appendChild(row);
  }
};

courseList.addEventListener("click", (event) => {
  const button = event.target.closest("button[data-course]");
  if (!button) return;

  const courseId = button.dataset.course;
  const selected = courses.find((course) => course.id === courseId);
  if (selected) {
    selectedCourseId = selected.id;
    renderModules(selected);
  }
});

moduleDetail.addEventListener("click", (event) => {
  const button = event.target.closest("button[data-module]");
  if (!button) return;

  const moduleIndex = Number(button.dataset.module);
  const selected = courses.find((course) => course.id === selectedCourseId);

  if (!selected || Number.isNaN(moduleIndex)) return;

  const module = selected.modules[moduleIndex];
  module.completed = !module.completed;

  renderModules(selected);
  renderCourses(searchInput.value);
  updateStats();
});

searchInput.addEventListener("input", (event) => {
  renderCourses(event.target.value);
});

resetSearch.addEventListener("click", () => {
  searchInput.value = "";
  renderCourses();
});

statusFilters.addEventListener("click", (event) => {
  const button = event.target.closest("button[data-filter]");
  if (!button) return;

  statusFilters.querySelectorAll(".filter").forEach((filterButton) => {
    filterButton.classList.toggle("active", filterButton === button);
  });

  activeCustomerFilter = button.dataset.filter;
  renderCustomers();
});

renderCourses();
renderCustomers();
updateStats();
