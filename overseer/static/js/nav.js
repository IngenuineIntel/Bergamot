const navToggle = document.getElementById('navtoggle');
const nav = document.getElementById('nav');

// toggle nav
navToggle.addEventListener('click', () => {
  if (nav.classList.contains('inactive')) {
    nav.classList.remove('inactive');
    nav.classList.add('active');
  } else { // nav is already open
    nav.classList.remove('active');
    nav.classList.add('inactive');
  }
});
