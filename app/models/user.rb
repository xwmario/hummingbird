class User < ActiveRecord::Base
  # Include devise modules. Others available are:
  # :token_authenticatable, :lockable, :timeoutable
  devise :database_authenticatable, :registerable, :recoverable, :rememberable,
         :trackable, :validatable, :omniauthable, :confirmable

  # Setup accessible (or protected) attributes for your model
  attr_accessible :name, :email, :password, :password_confirmation, :remember_me,
    :watchlist_hash, :recommendations_up_to_date, :avatar, :facebook_id, :bio

  has_attached_file :avatar, :styles => {:thumb => "200x200"},
    :default_url => "http://placekitten.com/g/200/200"
  
  has_many :watchlists
  has_many :reviews
  has_many :quotes

  has_one :staged_import

  has_reputation :karma, :source => [
    {reputation: :review_votes},
    {reputation: :quote_votes}
  ]

  has_reputation :review_votes, source: {reputation: :votes, of: :reviews}
  has_reputation :quote_votes,  source: {reputation: :votes, of: :quotes}

  # Validations
  validates :name,
    :presence   => true,
    :uniqueness => {:case_sensitive => false}
  
  validates :facebook_id, allow_blank: true, uniqueness: true

  def to_s
    name
  end

  # Avatar
  def avatar_url
    # Gravatar
    # gravatar_id = Digest::MD5.hexdigest(email.downcase)
    # "http://gravatar.com/avatar/#{gravatar_id}.png?s=100"
    avatar.url(:thumb)
  end

  # Public: Is this user an administrator?
  #
  # For now, this will just check email addresses. In production, this should
  # check the user's ID as well.
  def admin?
    (email == "c@vikhyat.net") or (email == "josh@hummingbird.ly")
  end

  # Public: Find a user corresponding to a Facebook account.
  #
  # If there is an account associated with the Facebook ID, return it.
  #
  # If there is no such account but `signed_in_resource` is not nil (meaning that
  # there is a user signed in), connect the user's account to this Facebook
  # account.
  #
  # If there is no user logged in, check to see if there is a user with the same
  # email address. If there is, connect that account to Facebook and return it.
  #
  # Otherwise, just create a new user and connect it to this Facebook account.
  #
  # Returns a user account corresponding to the given auth parameters.
  def self.find_for_facebook_oauth(auth, signed_in_resource=nil)
    # Try to find a user already associated with the Facebook ID.
    user = User.where(facebook_id: auth.uid).first
    return user if user
    
    # If the user is logged in, connect their account to Facebook.
    if not signed_in_resource.nil?
      signed_in_resource.connect_to_facebook(auth.uid)
      return signed_in_resource
    end
    
    # If there is a user with the same email, connect their account to this
    # Facebook account.
    user = User.find_by_email(auth.info.email)
    if user
      user.connect_to_facebook(auth.uid)
      return user
    end
    
    # Just create a new account. >_>
    user = User.new(
      name: auth.extra.raw_info.name,
      facebook_id: auth.uid,
      email: auth.info.email,
      avatar: URI.parse("http://graph.facebook.com/#{auth.uid}/picture?width=200&height=200"),
      password: Devise.friendly_token[0, 20]
    )
    user.skip_confirmation!
    user.save
    return user
  end
  
  # Set this user's facebook_id to the passed in `uid`.
  #
  # Returns nothing.
  def connect_to_facebook(uid)
    if not self.avatar.exists?
      self.avatar = URI.parse("http://graph.facebook.com/#{uid}/picture?width=200&height=200")
    end
    self.facebook_id = uid
    self.save
  end

  # Public: Return a hash table which returns false for all of the shows the user
  #         doesn't have on their watchlist, and the watchlist object for shows
  #         which they do have on.
  def watchlist_table
    watchlist = Hash.new(false)
    Watchlist.where(:user_id => id).each do |watch|
      watchlist[ watch.anime_id ] = watch
    end
    watchlist
  end

  # Return the top 3 genres the user has watched, along with a percentage of
  # anime watched that contain each of those genres.
  def top_genres
    genres        = Arel::Table.new(:genres)
    anime_genres  = Arel::Table.new(:anime_genres)
    watchlists_t  = Arel::Table.new(:watchlists)
    
    mywatchlists  = watchlists_t.where(watchlists_t[:user_id].eq(id))
    
    freqs = anime_genres.where(
              anime_genres[:anime_id].in( mywatchlists.project(:anime_id) )
            ).project(:genre_id, Arel.sql('COUNT(*) AS count'))
            .group(:genre_id).order('count DESC').take(3)
            
    result = {}
    
    connection.execute(freqs.to_sql).each do |h|
      result[ Genre.find(h["genre_id"]) ] = h["count"].to_f / watchlists.length
    end
    
    result
  end

  # How many minutes the user has spent watching anime.
  def recompute_life_spent_on_anime
    self.life_spent_on_anime = self.watchlists.map {|x| x.episodes.map(&:length).sum }.sum
    self.save
  end
  
  def update_life_spent_on_anime(delta)
    if life_spent_on_anime.nil?
      self.recompute_life_spent_on_anime
    else
      self.life_spent_on_anime += delta
      self.save
    end
  end
end
