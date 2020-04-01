# cython: language_level=3
# cython: boundscheck=False
# cython: wraparound=False


import numpy as np
from collections import namedtuple
from datetime import date
from cython.parallel import prange

cimport cython
cimport openmp
from cpython.mem cimport PyMem_Malloc, PyMem_Free
from libc.stdlib cimport malloc, free
cimport numpy as cnp

from cythonsim.simrandom cimport RandomPool


cdef enum SymptomSeverity:
    ASYMPTOMATIC
    MILD
    SEVERE
    CRITICAL


cdef enum PersonState:
    SUSCEPTIBLE
    INCUBATION
    ILLNESS
    HOSPITALIZED
    IN_ICU
    RECOVERED
    DEAD


ctypedef int int32
ctypedef unsigned char uint8
ctypedef unsigned int int16


cdef enum SimulationProblem:
    NO_PROBLEMOS
    TOO_MANY_INFECTEES
    HOSPITAL_ACCOUNTING_FAILURE
    MALLOC_FAILURE
    OTHER_FAILURE


DEF MAX_INFECTEES = 64


cdef struct Person:
    int32 idx, infector
    uint8 age, has_immunity, is_infected, was_detected, queued_for_testing, \
        symptom_severity, days_left, day_of_illness, day_of_infection, state, \
        included_in_totals
    int16 other_people_infected, other_people_exposed_today
    uint8 nr_infectees
    int32 *infectees

    openmp.omp_lock_t lock


cdef void person_init(Person *self, int32 idx, uint8 age) nogil:
    self.idx = idx
    self.age = age
    self.is_infected = 0
    self.was_detected = 0
    self.has_immunity = 0
    self.days_left = 0
    self.day_of_illness = 0
    self.day_of_infection = 0
    self.queued_for_testing = 0
    self.other_people_infected = 0
    self.included_in_totals = 0
    self.symptom_severity = SymptomSeverity.ASYMPTOMATIC
    self.state = PersonState.SUSCEPTIBLE
    self.nr_infectees = 0
    self.infector = -1
    self.infectees = NULL

    openmp.omp_init_lock(&self.lock)


STATE_TO_STR = {
    PersonState.SUSCEPTIBLE: 'SUSCEPTIBLE',
    PersonState.INCUBATION: 'INCUBATION',
    PersonState.ILLNESS: 'ILLNESS',
    PersonState.HOSPITALIZED: 'HOSPITALIZED',
    PersonState.IN_ICU: 'IN_ICU',
    PersonState.RECOVERED: 'RECOVERED',
    PersonState.DEAD: 'DEAD',
}
SEVERITY_TO_STR = {
    SymptomSeverity.ASYMPTOMATIC: 'ASYMPTOMATIC',
    SymptomSeverity.MILD: 'MILD',
    SymptomSeverity.SEVERE: 'SEVERE',
    SymptomSeverity.CRITICAL: 'CRITICAL',
}


cdef str person_print(Person *self):
    if self.infectees != NULL:
        infectees = '[%s]' % ', '.join(['%d' % self.infectees[i] for i in range(self.nr_infectees)])
    else:
        infectees = ''
    return 'Person %d: %d years, infection day %d, %s, %s, detected %d (others infected %d%s)' % (
        self.idx, self.age, self.day_of_illness, STATE_TO_STR[self.state],
        SEVERITY_TO_STR[self.symptom_severity], self.was_detected, self.other_people_infected,
        infectees
    )


cdef void person_infect(Person *self, Context context, Person *source=NULL) nogil:
    self.state = PersonState.INCUBATION
    self.symptom_severity = context.disease.get_symptom_severity(self, context)
    self.days_left = context.disease.get_incubation_days(self, context)
    self.is_infected = 1

    if source is not NULL:
        self.infector = source.idx
        if source.infectees != NULL:
            if source.nr_infectees >= MAX_INFECTEES:
                context.problem = SimulationProblem.TOO_MANY_INFECTEES
                return
            source.infectees[source.nr_infectees] = self.idx
            source.nr_infectees += 1

    if context.hc.testing_mode == TestingMode.ALL_WITH_SYMPTOMS_CT:
        if self.infectees != NULL:
            context.problem = SimulationProblem.OTHER_FAILURE
        else:
            self.infectees = <int32 *> malloc(sizeof(int32) * MAX_INFECTEES)
            if self.infectees == NULL:
                context.problem = SimulationProblem.MALLOC_FAILURE

    context.pop.infect(self)


cdef bint person_expose(Person *self, Context context, Person *source) nogil:
    if self.is_infected or self.has_immunity:
        return False
    if context.disease.did_infect(self, context, source):
        person_infect(self, context, source)
        return True
    return False


"""
cdef inline DailyContacts * _get_daily_contacts(Person *self) nogil:
    cdef DailyContacts *dc
    cdef int min_idx, i

    min_idx = 0
    for i in range(DAILY_CONTACTS_DAYS):
        dc = self.daily_contacts[i]
        if dc == NULL:
            min_idx = i
            break
        if self.daily_contacts[min_idx].day < dc.day:
            min_idx = i

    dc = self.daily_contacts[min_idx]
    if dc == NULL:
        dc = <DailyContacts *> malloc(sizeof(DailyContacts))
        if dc == NULL:
            return NULL
        self.daily_contacts[min_idx] = dc

    return dc
"""

@cython.cdivision(True)
cdef void person_expose_others(Person *self, Context context, int nr_contacts) nogil:
    cdef Person *people = context.people
    cdef int32 *infectees = self.infectees
    cdef int exposee_idx, total, i, infected_idx
    cdef Person *target

    self.other_people_exposed_today = nr_contacts
    infected_idx = 0
    for i in range(nr_contacts):
        exposee_idx = context.random.getint() % context.total_people
        target = &people[exposee_idx]
        if person_expose(target, context, self):
            if infectees != NULL:
                if self.other_people_infected >= MAX_INFECTEES:
                    context.problem = SimulationProblem.TOO_MANY_INFECTEES
                    break
                infectees[self.other_people_infected] = exposee_idx
            self.other_people_infected += 1


cdef void person_become_ill(Person *self, Context context) nogil:
    self.state = PersonState.ILLNESS
    self.days_left = context.disease.get_illness_days(self, context)
    if self.symptom_severity != SymptomSeverity.ASYMPTOMATIC:
        # People with symptoms seek testing (but might not get it)
        if not self.was_detected:
            context.hc.seek_testing(self, context)


cdef void person_detect(Person *self, Context context) nogil:
    self.was_detected = 1
    context.pop.detect(self)


cdef void person_become_removed(Person *self, Context context) nogil:
    self.is_infected = 0
    self.has_immunity = 1

    if self.infectees != NULL:
        free(self.infectees)
        self.infectees = NULL


cdef void person_dealloc(Person *self) nogil:
    if self.infectees != NULL:
        free(self.infectees)


cdef void person_recover(Person *self, Context context) nogil:
    self.state = PersonState.RECOVERED
    person_become_removed(self, context)
    context.pop.recover(self)


cdef void person_hospitalize(Person *self, Context context) nogil:
    if not self.was_detected:
        person_detect(self, context)

    if self.symptom_severity == SymptomSeverity.CRITICAL:
        if not context.hc.to_icu():
            # If no ICU units are available, ...
            person_die(self, context)
            return
        self.state = PersonState.IN_ICU
        self.days_left = context.disease.get_icu_days(self, context)
    else:
        if not context.hc.hospitalize(self):
            # If no beds are available, there's a chance to die.
            if context.disease.dies_in_hospital(self, context, in_icu=False, care_available=False):
                person_die(self, context)
            else:
                person_recover(self, context)
            return

        self.state = PersonState.HOSPITALIZED
        self.days_left = context.disease.get_hospitalization_days(self, context)

    context.pop.hospitalize(self)
    if self.state == PersonState.IN_ICU:
        context.pop.transfer_to_icu(self)


cdef void person_release_from_hospital(Person *self, Context context) nogil:
    context.pop.release_from_hospital(self)
    if self.state == PersonState.IN_ICU:
        death = context.disease.dies_in_hospital(self, context, in_icu=True, care_available=True)
        context.pop.release_from_icu(self)
        context.hc.release_from_icu()
    else:
        death = context.disease.dies_in_hospital(self, context, in_icu=False, care_available=True)
        context.hc.release()

    if death:
        person_die(self, context)
    else:
        person_recover(self, context)


cdef void person_die(Person *self, Context context) nogil:
    # This is a way to get long-lasting immunity.
    self.state = PersonState.DEAD
    context.pop.die(self)
    person_become_removed(self, context)


cdef void person_advance(Person *self, Context context) nogil:
    cdef int people_exposed
    self.other_people_exposed_today = 0

    if self.state == PersonState.INCUBATION:
        people_exposed = context.disease.people_exposed(self, context)
        if people_exposed:
            person_expose_others(self, context, people_exposed)

        self.days_left -= 1
        if self.days_left == 0:
            person_become_ill(self, context)
    elif self.state == PersonState.ILLNESS:
        people_exposed = context.disease.people_exposed(self, context)
        if people_exposed:
            person_expose_others(self, context, people_exposed)

        self.day_of_illness += 1
        self.days_left -= 1
        if self.days_left == 0:
            # People with mild symptoms recover after the symptomatic period
            # and people with more severe symptoms are hospitalized.
            if self.symptom_severity in (SymptomSeverity.SEVERE, SymptomSeverity.CRITICAL):
                person_hospitalize(self, context)
            else:
                person_recover(self, context)
    elif self.state in (PersonState.HOSPITALIZED, PersonState.IN_ICU):
        self.days_left -= 1
        if self.days_left == 0:
            person_release_from_hospital(self, context)

    self.day_of_infection += 1


cdef enum TestingMode:
    NO_TESTING
    ALL_WITH_SYMPTOMS_CT
    ALL_WITH_SYMPTOMS
    ONLY_SEVERE_SYMPTOMS


DEF TESTING_TRACE = False


cdef class HealthcareSystem:
    cdef int32 beds, icu_units, available_beds, available_icu_units
    cdef int32 tests_run_per_day
    cdef float p_detected_anyway
    cdef TestingMode testing_mode
    cdef list testing_queue
    cdef openmp.omp_lock_t lock

    def __init__(self, beds, icu_units, p_detected_anyway):
        self.beds = beds
        self.icu_units = icu_units
        self.available_beds = beds
        self.available_icu_units = icu_units
        self.testing_mode = TestingMode.NO_TESTING
        self.testing_queue = []
        self.tests_run_per_day = 0
        self.p_detected_anyway = p_detected_anyway
        openmp.omp_init_lock(&self.lock)

    cdef bint queue_for_testing(self, int person_idx, Context context) nogil:
        cdef Person *p = context.people + person_idx
        if p.state == PersonState.DEAD or p.was_detected or p.queued_for_testing:
            return False
        p.queued_for_testing = 1
        with gil:
            self.testing_queue.append(person_idx)
            IF TESTING_TRACE == True:
                print('Person %d to test queue' % person_idx)
        return True

    cdef void perform_contact_tracing(self, int person_idx, Context context, int level) nogil:
        cdef Person *p = context.people + person_idx
        cdef int infectee_idx
        if level > 1:
            return

        IF TESTING_TRACE == True:
            with gil:
                print('%sContact tracing person: %s' % (level * '  ', person_print(p)))

        if p.infector >= 0:
            if self.queue_for_testing(p.infector, context):
                self.perform_contact_tracing(p.infector, context, level + 1)
        if p.infectees != NULL:
            for i in range(p.nr_infectees):
                infectee_idx = p.infectees[i]
                if self.queue_for_testing(infectee_idx, context):
                    self.perform_contact_tracing(infectee_idx, context, level + 1)

    cdef iterate(self, Context context):
        cdef Person *person
        cdef int idx

        queue = self.testing_queue
        self.tests_run_per_day = len(queue)
        self.testing_queue = []

        # Run tests
        for idx in queue:
            person = context.people + idx
            if not person.queued_for_testing:
                raise Exception()
            person.queued_for_testing = 1

            if not person.is_infected or person.was_detected:
                continue

            if not self.is_detected(person, context):
                continue

            # Infection is detected
            IF TESTING_TRACE == True:
                print('Person %d detected' % idx)
            person_detect(person, context)
            if self.testing_mode == TestingMode.ALL_WITH_SYMPTOMS_CT:
                # With contact tracing we queue the infector and the
                # infectees for testing.
                # FIXME: Simulate non-perfect contact tracing?
                self.perform_contact_tracing(idx, context, 0)

    cdef void seek_testing(self, Person *person, Context context) nogil:
        IF TESTING_TRACE == True:
            with gil:
                print('Person %d seeks testing' % person.idx)
        queue_for_testing = False
        if self.testing_mode in (TestingMode.ALL_WITH_SYMPTOMS, TestingMode.ALL_WITH_SYMPTOMS_CT):
            queue_for_testing = True
        elif self.testing_mode == TestingMode.ONLY_SEVERE_SYMPTOMS:
            if person.symptom_severity in (SymptomSeverity.SEVERE, SymptomSeverity.CRITICAL):
                queue_for_testing = True
            elif context.random.chance(self.p_detected_anyway):
                # Some people get tests anyway (healthcare workers etc.)
                queue_for_testing = True

                # with gil:
                #    print('Day %d. Seek testing and got it' % context.day)
                #    person_print(person)

        if queue_for_testing:
            self.queue_for_testing(person.idx, context)

    cdef bint hospitalize(self, Person *person) nogil:
        if self.available_beds == 0:
            return False
        self.available_beds -= 1
        return True

    def set_testing_mode(self, mode):
        self.testing_mode = mode

    cdef bint is_detected(self, Person *person, Context context) nogil:
        # Person needs to have viral load in order to be detected
        if context.disease.get_source_infectiousness(person):
            # FIXME: Factor in sensitivity?
            return True

        if person.state in (PersonState.HOSPITALIZED, PersonState.IN_ICU):
            return True
        return False

    cdef void release(self) nogil:
        self.available_beds += 1

    cdef bint to_icu(self) nogil:
        if self.available_icu_units == 0:
            return False
        self.available_icu_units -= 1
        return True

    cdef void release_from_icu(self) nogil:
        self.available_icu_units += 1


# The infectiousness profile of the pathogen over time.
# Day 0 is the symptom onset day.
# Source: https://www.medrxiv.org/content/10.1101/2020.03.15.20036707v2.full.pdf
INFECTIOUSNESS_OVER_TIME = (
    (-2, 0.12),
    (-1, 0.29),
    (0, 0.27),
    (1, 0.07),
    (2, 0.05),
    (3, 0.04),
    (4, 0.03),
    (5, 0.02),
    (6, 0.02),
    (7, 0.01),
    (8, 0.01),
    (9, 0.01),
    (10, 0.01),
)

cdef class ClassedValues:
    cdef int[::1] classes
    cdef float[::1] values

    def __init__(self, pairs):
        self.classes = np.array([x[0] for x in pairs], dtype='i')
        self.values = np.array([x[1] for x in pairs], dtype='f')

    cdef float get(self, int kls, float default) nogil:
        cdef int idx;

        for idx in range(len(self.classes)):
            if self.classes[idx] == kls:
                return self.values[idx]
        return default

    cdef float get_greatest_lte(self, int kls) nogil:
        """Returns the greatest value less-than-or-equal to the given class""" 
        cdef int idx = 0
        cdef float last

        for idx in range(len(self.classes)):
            if self.classes[idx] > kls:
                break
        return self.values[idx]


DISEASE_PARAMS = (
    'p_infection', 'p_asymptomatic', 'p_severe', 'p_critical', 'p_hospital_death',
    'p_icu_death', 'p_hospital_death_no_beds', 'p_icu_death_no_beds',
    'mean_illness_duration', 'mean_hospitalization_duration', 'mean_icu_duration'
)

cdef class Disease:
    cdef float p_infection, p_asymptomatic, p_hospital_death, p_icu_death
    cdef float p_icu_death_no_beds, p_hospital_death_no_beds
    cdef float mean_illness_duration, mean_hospitalization_duration, mean_icu_duration
    cdef ClassedValues p_severe
    cdef ClassedValues p_critical
    cdef ClassedValues infectiousness_over_time

    def __init__(self,
        p_infection, p_asymptomatic, p_severe, p_critical, p_hospital_death,
        p_icu_death, p_hospital_death_no_beds, p_icu_death_no_beds,
        mean_illness_duration, mean_hospitalization_duration, mean_icu_duration
    ):
        self.p_infection = p_infection
        self.p_asymptomatic = p_asymptomatic

        self.p_hospital_death = p_hospital_death
        self.p_icu_death = p_icu_death
        self.p_hospital_death_no_beds = p_hospital_death_no_beds
        self.p_icu_death_no_beds = p_icu_death_no_beds

        self.mean_illness_duration = mean_illness_duration
        self.mean_hospitalization_duration = mean_hospitalization_duration
        self.mean_icu_duration = mean_icu_duration

        self.p_severe = ClassedValues(p_severe)
        self.p_critical = ClassedValues(p_critical)
        self.infectiousness_over_time = ClassedValues(INFECTIOUSNESS_OVER_TIME)

    @classmethod
    def from_variables(cls, variables):
        args = []
        for name in DISEASE_PARAMS:
            args.append(variables[name])
        return cls(*args)

    cdef float get_infectiousness_over_time(self, int day) nogil:
        return self.infectiousness_over_time.get(day, 0) * self.p_infection

    cdef float get_source_infectiousness(self, Person *source) nogil:
        cdef int day

        if source.state == PersonState.INCUBATION:
            day = -source.days_left
        elif source.state == PersonState.ILLNESS:
            day = source.day_of_illness
        else:
            return 0
        return self.infectiousness_over_time.get(day, 0) * self.p_infection

    cdef bint did_infect(self, Person *person, Context context, Person *source) nogil:
        cdef float chance = self.get_source_infectiousness(source)
        # FIXME: Smaller chance for asymptomatic people?
        return context.random.chance(chance)

    cdef int people_exposed(self, Person *person, Context context) nogil:
        # Detected people are quarantined
        if person.was_detected:
            return 0

        # If we are not infectious today, we expose 0 people.
        if not self.get_source_infectiousness(person):
            return 0

        if person.state == PersonState.INCUBATION:
            return context.pop.contacts_per_day(person, context)
        elif person.state == PersonState.ILLNESS:
            # Asymptomatic people infect others without knowing it
            if person.symptom_severity == SymptomSeverity.ASYMPTOMATIC:
                return context.pop.contacts_per_day(person, context)
            else:
                # People with mild or more severe symptoms restrict their movement
                return context.pop.contacts_per_day(person, context, factor=0.5, limit=5)

        return 0

    cdef bint dies_in_hospital(self, Person *person, Context context, bint in_icu, bint care_available) nogil:
        if in_icu:
            if care_available:
                chance = self.p_icu_death
            else:
                chance = self.p_icu_death_no_beds
        else:
            if care_available:
                chance = self.p_hospital_death
            else:
                chance = self.p_hospital_death_no_beds

        return context.random.chance(chance)

    cdef int get_incubation_days(self, Person *person, Context context) nogil:
        # lognormal distribution, mode on 5 days
        # Source: https://www.medrxiv.org/content/10.1101/2020.03.15.20036707v2.full.pdf
        cdef float f = context.random.lognormal(1.0, 0.4) * 1.5
        cdef int days = 1 + <int> f
        if days > 14:
            days = 14
        return days

    cdef int get_illness_days(self, Person *person, Context context) nogil:
        cdef float f = context.random.lognormal(0, 0.6)
        f *= self.mean_illness_duration
        cdef int days = 1 + <int> f
        if days > 40:
            days = 40
        return days

    cdef int get_hospitalization_days(self, Person *person, Context context) nogil:
        cdef float f = context.random.lognormal(0, 0.5)
        f *= self.mean_hospitalization_duration
        cdef int days = 1 + <int> f
        if days > 50:
            days = 50
        return days

    cdef int get_icu_days(self, Person *person, Context context) nogil:
        cdef float f = context.random.lognormal(0, 0.3)
        f *= self.mean_icu_duration
        cdef int days = 1 + <int> f
        if days > 50:
            days = 50
        return days

    cdef SymptomSeverity get_symptom_severity(self, Person *person, Context context) nogil:
        cdef int i
        cdef float sc, cc, val

        val = context.random.get()
        sc = self.p_severe.get_greatest_lte(person.age)
        cc = self.p_critical.get_greatest_lte(person.age)

        if val < sc * cc:
            return SymptomSeverity.CRITICAL
        if val < sc:
            return SymptomSeverity.SEVERE
        if val < 1 - self.p_asymptomatic:
            return SymptomSeverity.MILD
        return SymptomSeverity.ASYMPTOMATIC


MODEL_STATE_FIELDS = [
    'susceptible', 'infected', 'all_infected',
    'detected', 'all_detected',
    'hospitalized', 'in_icu', 'dead', 'recovered',
    'available_hospital_beds', 'available_icu_units',
    'r', 'exposed_per_day', 'tests_run_per_day',
]
ModelState = namedtuple('ModelState', MODEL_STATE_FIELDS)


cdef class Population:
    cdef int[::1] infected, detected, all_detected, all_infected, hospitalized, \
        in_icu, dead, susceptible, recovered
    cdef ClassedValues avg_contacts_per_day
    cdef int limit_mass_gatherings
    cdef float population_mobility_factor

    def __init__(self, age_counts, avg_contacts_per_day):
        nr_ages = len(age_counts)

        self.susceptible = np.array(age_counts, dtype=np.int32)
        self.infected = np.zeros(nr_ages, dtype=np.int32)
        self.detected = np.zeros(nr_ages, dtype=np.int32)
        self.all_detected = np.zeros(nr_ages, dtype=np.int32)
        self.all_infected = np.zeros(nr_ages, dtype=np.int32)
        self.recovered = np.zeros(nr_ages, dtype=np.int32)
        self.hospitalized = np.zeros(nr_ages, dtype=np.int32)
        self.in_icu = np.zeros(nr_ages, dtype=np.int32)
        self.dead = np.zeros(nr_ages, dtype=np.int32)
        self.avg_contacts_per_day = ClassedValues(avg_contacts_per_day)
        self.limit_mass_gatherings = 0
        self.population_mobility_factor = 1.0

    cdef int contacts_per_day(self, Person *person, Context context, float factor=1.0, int limit=100) nogil:
        # Contacts per day follows a lognormal distribution with
        # mean at `avg_contacts_per_day`.
        cdef float f = factor * self.population_mobility_factor
        f *= context.random.lognormal(0, 0.5) * self.avg_contacts_per_day.get_greatest_lte(person.age)

        cdef int contacts = <int> f - 1
        if self.limit_mass_gatherings:
            if contacts > self.limit_mass_gatherings:
                contacts = self.limit_mass_gatherings
        if contacts > limit:
            contacts = limit
        return contacts

    cdef void infect(self, Person *person) nogil:
        age = person.age
        self.susceptible[age] -= 1
        self.infected[age] += 1
        self.all_infected[age] += 1

    cdef void recover(self, Person *person) nogil:
        cdef int age = person.age
        self.infected[age] -= 1
        self.recovered[age] += 1
        if person.was_detected:
            self.detected[age] -= 1

    cdef void detect(self, Person *person) nogil:
        cdef int age = person.age
        self.detected[age] += 1
        self.all_detected[age] += 1

    cdef void hospitalize(self, Person *person) nogil:
        self.hospitalized[person.age] += 1

    cdef void transfer_to_icu(self, Person *person) nogil:
        self.in_icu[person.age] += 1

    cdef void release_from_icu(self, Person *person) nogil:
        self.in_icu[person.age] -= 1

    cdef void release_from_hospital(self, Person *person) nogil:
        self.hospitalized[person.age] -= 1

    cdef void die(self, Person *person) nogil:
        cdef int age = person.age
        self.infected[age] -= 1
        self.dead[age] += 1
        if person.was_detected:
            self.detected[age] -= 1


cdef class Intervention:
    cdef public int day
    cdef public str name
    cdef public int value

    def __init__(self, day, name, value):
        self.day = day
        self.name = name
        self.value = value


cdef class Context:
    cdef public Population pop
    cdef public HealthcareSystem hc
    cdef public Disease disease
    cdef public RandomPool random
    cdef SimulationProblem problem
    cdef int day
    cdef Person *people
    cdef int total_people
    cdef list interventions
    cdef str start_date
    cdef int total_infections, total_infectors, exposed_per_day

    def __init__(self, Population pop, HealthcareSystem hc, Disease disease, str start_date):
        self.create_population(pop.susceptible)

        self.problem = SimulationProblem.NO_PROBLEMOS
        self.pop = pop
        self.hc = hc
        self.disease = disease
        self.random = RandomPool()
        self.start_date = start_date
        self.day = 0
        self.interventions = []

        # Per day
        self.total_infectors = 0
        self.total_infections = 0
        self.exposed_per_day = 0


    def add_intervention(self, day, name, value):
        if value is None:
            value = 0
        self.interventions.append(Intervention(day, name, value))

    cdef void _free_people(self) nogil:
        cdef Person *p

        for i in range(self.total_people):
            p = &self.people[i]
            person_dealloc(p)

    def __dealloc__(self):
        self._free_people()
        PyMem_Free(self.people)

    cdef Person *get_people(self):
        return self.people

    cdef float lognormal(self, float mean=0.0, float sigma=1.0) nogil:
        return self.random.lognormal(mean, sigma)

    cdef create_population(self, age_counts):
        cdef int idx
        cdef Person *p

        total = 0
        for age, count in enumerate(age_counts):
            total += count

        people = <Person *> PyMem_Malloc(total * sizeof(Person))
        idx = 0
        for age, count in enumerate(age_counts):
            for i in range(count):
                p = people + idx
                person_init(p, idx, age)
                idx += 1
        self.total_people = total
        self.people = people

    def generate_state(self):
        p = self.pop
        hc = self.hc
        r = self.total_infections / self.total_infectors if self.total_infectors > 5 else 0
        s = ModelState(
            infected=p.infected, susceptible=p.susceptible,
            all_infected=p.all_infected,
            recovered=p.recovered, hospitalized=p.hospitalized,
            in_icu=p.in_icu,
            detected=p.detected, all_detected=p.all_detected,
            dead=p.dead,
            available_icu_units=hc.available_icu_units,
            available_hospital_beds=hc.available_beds,
            r=r,
            exposed_per_day=self.exposed_per_day,
            tests_run_per_day=self.hc.tests_run_per_day,
        )
        return s

    def infect_people(self, count):
        cdef int idx
        cdef Person *person

        for i in range(count):
            idx = self.random.getint() % self.total_people
            person = self.people + idx
            person_infect(person, self)

    def apply_intervention(self, intervention):
        if intervention.name == 'test-all-with-symptoms':
            # Start testing everyone who shows even mild symptoms
            self.hc.set_testing_mode(TestingMode.ALL_WITH_SYMPTOMS)
        elif intervention.name == 'test-only-severe-symptoms':
            # Test only those who show severe or critical symptoms
            self.hc.set_testing_mode(TestingMode.ONLY_SEVERE_SYMPTOMS)
        elif intervention.name == 'test-with-contact-tracing':
            # Test only those who show severe or critical symptoms
            self.hc.set_testing_mode(TestingMode.ALL_WITH_SYMPTOMS_CT)
        elif intervention.name == 'build-new-icu-units':
            self.hc.icu_units += intervention.value
            self.hc.available_icu_units += intervention.value
        elif intervention.name == 'build-new-hospital-beds':
            self.hc.beds += intervention.value
            self.hc.available_beds += intervention.value
        elif intervention.name == 'import-infections':
            # Introduct infections from elsewhere
            count = intervention.value
            self.infect_people(count)
        elif intervention.name == 'limit-mass-gatherings':
            self.pop.limit_mass_gatherings = intervention.value
        elif intervention.name == 'limit-mobility':
            self.pop.population_mobility_factor = (100 - intervention.value) / 100.0
        else:
            raise Exception()

    cdef void _iterate(self):
        cdef Person *person
        cdef int idx;

        for intervention in self.interventions:
            if intervention.day == self.day:
                # print(intervention.name)
                self.apply_intervention(intervention)

        self.total_infectors = 0
        self.total_infections = 0
        self.exposed_per_day = 0

        self.hc.iterate(self)

        for idx in prange(self.total_people, nogil=True, num_threads=1, schedule='dynamic', chunksize=10000):
            person = self.people + idx
            if person.state in (PersonState.RECOVERED, PersonState.DEAD) and not person.included_in_totals:
                self.total_infectors += 1
                self.total_infections += person.other_people_infected
                person.included_in_totals = 1

            if not person.is_infected:
                continue

            person_advance(person, self)

            self.exposed_per_day += person.other_people_exposed_today

        if self.problem != SimulationProblem.NO_PROBLEMOS:
            raise Exception('Simulation failed with %d' % self.problem)

        self.day += 1

    def iterate(self):
        self._iterate()

    cpdef sample(self, str what, int age):
        cdef int sample_size = 10000
        cdef Person p = self.people[0]
        cdef cnp.ndarray[int] out
        cdef int i

        p.age = age
        if what == 'infectiousness':
            days = list(range(-100, 100))
            vals = [self.disease.get_infectiousness_over_time(day) for day in days]
            ret = np.rec.fromarrays((days, vals), names=('day', 'val'))
            return ret

        out = np.empty(sample_size, dtype='i')
        with nogil:
            if what == 'contacts_per_day':
                for i in range(sample_size):
                    out[i] = self.pop.contacts_per_day(&p, self)
            elif what == 'symptom_severity':
                for i in range(sample_size):
                    out[i] = self.disease.get_symptom_severity(&p, self)
            elif what == 'incubation_period':
                for i in range(sample_size):
                    out[i] = self.disease.get_incubation_days(&p, self)
            elif what == 'illness_period':
                for i in range(sample_size):
                    out[i] = self.disease.get_illness_days(&p, self)
            elif what == 'hospitalization_period':
                for i in range(sample_size):
                    out[i] = self.disease.get_hospitalization_days(&p, self)
            elif what == 'icu_period':
                for i in range(sample_size):
                    out[i] = self.disease.get_icu_days(&p, self)
            else:
                with gil:
                    raise Exception('unknown sample type')

        return out


def make_iv(context, intervention, date_str=None, value=None):
    if date_str is not None:
        day = (date.fromisoformat(date_str) - date.fromisoformat(context.start_date)).days
    else:
        day = 0
    return Intervention(day, intervention, value or 0)
